"""Harbor installed-agent adapter for the Forgelet CLI."""

from __future__ import annotations

import os
import shlex
import uuid
from pathlib import Path

from harbor.agents.installed.base import BaseInstalledAgent, with_prompt_template
from harbor.agents.utils import get_api_key_var_names_from_model_name
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext

_NODE_PREBUILT_REL = ".node-prebuilt/node-v20"
_CONTAINER_NODE = "/opt/node-v20"
_AGENT_DIR = Path(__file__).resolve().parent
_DEFAULT_FORGELET_INSTALL = "/forgelet"
_DEFAULT_PROMPT_EXTRA = "/installed-agent/prompt-extra.txt"
_CLI_ENTRY = "/forgelet/apps/cli/src/main.ts"
_TSX_CLI = "/forgelet/node_modules/tsx/dist/cli.mjs"


def _provider_from_model(model_name: str) -> str:
    if "/" not in model_name:
        return "custom"
    provider, _ = model_name.split("/", 1)
    return provider.lower()


def _short_model(model_name: str) -> str:
    if "/" in model_name:
        return model_name.split("/", 1)[1]
    return model_name


class ForgeletAgent(BaseInstalledAgent):
    """Run Forgelet inside a Harbor task container."""

    SUPPORTS_ATIF: bool = False

    @staticmethod
    def name() -> str:
        return "forgelet"

    def version(self) -> str | None:
        return self._version or "0.1.0"

    def get_version_command(self) -> str | None:
        return f"node {_TSX_CLI} --version 2>/dev/null || node --version"

    async def _forgelet_ready(self, environment: BaseEnvironment) -> bool:
        result = await environment.exec(
            command=f"test -f {_TSX_CLI} && test -f {_CLI_ENTRY}",
        )
        return result.return_code == 0

    async def _install_node(self, environment: BaseEnvironment) -> None:
        result = await environment.exec(command="command -v node >/dev/null 2>&1")
        if result.return_code == 0:
            return

        forgelet_root = os.environ.get("FORGELET_ROOT", "").strip()
        node_src = (
            Path(forgelet_root).expanduser().resolve() / _NODE_PREBUILT_REL
            if forgelet_root
            else None
        )
        if node_src and (node_src / "bin" / "node").is_file():
            self.logger.info("Uploading bundled Node.js %s → %s", node_src, _CONTAINER_NODE)
            await environment.upload_dir(node_src, _CONTAINER_NODE)
            await self.exec_as_root(
                environment,
                command=(
                    "set -euo pipefail; "
                    f"test -x {_CONTAINER_NODE}/bin/node; "
                    "ln -sf /opt/node-v20/bin/node /usr/local/bin/node; "
                    "ln -sf /opt/node-v20/bin/npm /usr/local/bin/npm; "
                    "ln -sf /opt/node-v20/bin/npx /usr/local/bin/npx; "
                    "ln -sf /opt/node-v20/bin/corepack /usr/local/bin/corepack 2>/dev/null || true"
                ),
            )
            return

        raise RuntimeError(
            "Task container has no Node.js and cannot reach package mirrors. "
            f"Bundle Linux Node under FORGELET_ROOT/{_NODE_PREBUILT_REL} "
            "(run prepare-forgelet.sh) instead of apt-get install."
        )

    async def _stage_forgelet(self, environment: BaseEnvironment) -> None:
        if await self._forgelet_ready(environment):
            self.logger.debug("Forgelet already present at %s", _DEFAULT_FORGELET_INSTALL)
            return

        forgelet_root = os.environ.get("FORGELET_ROOT", "").strip()
        if not forgelet_root:
            raise ValueError(
                "Forgelet is not pre-installed in the container and FORGELET_ROOT is unset. "
                "Run prepare-forgelet.sh on the host, then export FORGELET_ROOT to that "
                "staging directory before harbor run."
            )

        source = Path(forgelet_root).expanduser().resolve()
        if not source.is_dir():
            raise ValueError(f"FORGELET_ROOT is not a directory: {source}")

        self.logger.info("Uploading Forgelet staging dir %s → %s", source, _DEFAULT_FORGELET_INSTALL)
        await environment.upload_dir(source, _DEFAULT_FORGELET_INSTALL)

        if await self._forgelet_ready(environment):
            return

        await self.exec_as_agent(
            environment,
            command=(
                f"set -euo pipefail; cd {_DEFAULT_FORGELET_INSTALL}; "
                "if command -v pnpm >/dev/null 2>&1; then "
                "  ELECTRON_SKIP_BINARY_DOWNLOAD=1 pnpm install --ignore-scripts; "
                "elif command -v npm >/dev/null 2>&1; then "
                "  npm install -g pnpm@8 && ELECTRON_SKIP_BINARY_DOWNLOAD=1 pnpm install --ignore-scripts; "
                "else "
                '  echo "pnpm/npm not found after Node install" >&2; exit 1; '
                "fi"
            ),
            timeout_sec=1800,
        )

    async def _upload_prompt_extra(self, environment: BaseEnvironment) -> None:
        extra_path = _AGENT_DIR / "prompt-extra.txt"
        if not extra_path.is_file():
            return
        marker = f"PROMPT_EXTRA_EOF_{uuid.uuid4().hex[:8]}"
        content = extra_path.read_text()
        await self.exec_as_root(
            environment,
            command=(
                "mkdir -p /installed-agent\n"
                f"cat > {_DEFAULT_PROMPT_EXTRA} << '{marker}'\n"
                f"{content}\n"
                f"{marker}\n"
            ),
        )

    async def install(self, environment: BaseEnvironment) -> None:
        preinstalled = os.environ.get("FORGELET_PREINSTALLED", "").strip().lower() in {
            "1",
            "true",
            "yes",
            "on",
        }
        if not preinstalled:
            await self._install_node(environment)
            await self._stage_forgelet(environment)
        elif not await self._forgelet_ready(environment):
            raise RuntimeError(
                "FORGELET_PREINSTALLED=1 but Forgelet binaries are missing in the container"
            )

        await self._upload_prompt_extra(environment)

        if not await self._forgelet_ready(environment):
            raise RuntimeError("Forgelet install failed: tsx CLI or main.ts not found")

    def _build_run_env(self) -> dict[str, str]:
        if not self.model_name:
            raise ValueError("model_name is required (pass --model provider/model to harbor run)")

        env: dict[str, str] = {
            "FORGELET_TASK_HINT": "terminal",
            "FORGELET_PROMPT_EXTRA_FILE": _DEFAULT_PROMPT_EXTRA,
            "FORGELET_BASH_TIMEOUT_MS": os.environ.get("FORGELET_BASH_TIMEOUT_MS", "180000"),
            "FORGELET_REASON": os.environ.get("FORGELET_REASON", "0"),
            "FORGELET_VERIFY": os.environ.get("FORGELET_VERIFY", "0"),
            "FORGELET_PROVIDER": _provider_from_model(self.model_name),
            "FORGELET_MODEL": _short_model(self.model_name),
        }

        if "FORGELET_API_KEY" in os.environ and os.environ["FORGELET_API_KEY"].strip():
            env["FORGELET_API_KEY"] = os.environ["FORGELET_API_KEY"]
        else:
            for key in get_api_key_var_names_from_model_name(self.model_name):
                if key in os.environ and os.environ[key].strip():
                    env[key] = os.environ[key]
                    break
            else:
                raise ValueError(
                    f"No API key found for model {self.model_name}. "
                    "Set FORGELET_API_KEY or the provider-specific key in the environment."
                )

        for passthrough in (
            "DEEPSEEK_API_KEY",
            "OPENAI_API_KEY",
            "ANTHROPIC_API_KEY",
            "FORGELET_BASE_URL",
            "OPENAI_API_BASE",
        ):
            if (
                passthrough in os.environ
                and os.environ[passthrough].strip()
                and passthrough not in env
            ):
                env[passthrough] = os.environ[passthrough]

        env.update(self.resolve_env_vars())
        return env

    @with_prompt_template
    async def run(
        self,
        instruction: str,
        environment: BaseEnvironment,
        context: AgentContext,
    ) -> None:
        env = self._build_run_env()
        escaped_instruction = shlex.quote(instruction)
        workdir = os.environ.get("FORGELET_WORKDIR", "").strip() or "$HOME"
        agent_timeout = os.environ.get("FORGELET_AGENT_TIMEOUT_SEC", "600")

        command = (
            f"set -euo pipefail; "
            f"cd {workdir}; "
            f"timeout {shlex.quote(agent_timeout)} "
            f"node {_TSX_CLI} {_CLI_ENTRY} "
            f"-c \"$(pwd)\" -y --no-trace {escaped_instruction}"
        )

        await self.exec_as_agent(environment, command=command, env=env, timeout_sec=int(agent_timeout) + 60)
