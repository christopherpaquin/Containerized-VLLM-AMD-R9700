"""
Unit and integration tests for OpenCode configuration and verification scripts.

Tests all configuration, compaction settings, rule installation, plugin deployment,
idempotency, backup behavior, and verify-opencode.sh diagnostics in isolated
temporary directories without touching the user's live OpenCode configuration.
"""

import json
import os
import subprocess
from pathlib import Path
import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
CONFIGURE_SCRIPT = REPO_ROOT / "scripts" / "configure-opencode.sh"
CONFIGURE_RULES_SCRIPT = REPO_ROOT / "scripts" / "configure-opencode-rules.sh"
VERIFY_SCRIPT = REPO_ROOT / "scripts" / "verify-opencode.sh"


@pytest.fixture
def temp_config_dir(tmp_path):
    """Provides an isolated temporary OpenCode config directory."""
    config_dir = tmp_path / "opencode"
    config_dir.mkdir(parents=True, exist_ok=True)
    return config_dir


def run_script(script_path, args=None, env=None, check=True):
    """Helper to run a repository bash script with custom env."""
    args = args or []
    full_env = os.environ.copy()
    if env:
        full_env.update(env)

    result = subprocess.run(
        [str(script_path)] + args,
        cwd=str(REPO_ROOT),
        env=full_env,
        capture_output=True,
        text=True,
    )
    if check and result.returncode != 0:
        raise RuntimeError(
            f"Script {script_path} failed with code {result.returncode}:\n"
            f"STDOUT:\n{result.stdout}\n"
            f"STDERR:\n{result.stderr}"
        )
    return result


def test_fresh_configuration(temp_config_dir):
    """Test configure-opencode.sh on a completely fresh environment."""
    env = {"OPENCODE_CONFIG_DIR": str(temp_config_dir)}
    res = run_script(CONFIGURE_SCRIPT, env=env)
    assert res.returncode == 0

    # 1. Check opencode.json exists and is valid JSON
    config_file = temp_config_dir / "opencode.json"
    assert config_file.exists()
    data = json.loads(config_file.read_text())

    # Provider and model
    assert "scar-vllm" in data.get("provider", {})
    provider = data["provider"]["scar-vllm"]
    assert provider["options"]["baseURL"].endswith("/v1")
    assert "qwen3-coder-30b-a3b" in provider["models"]
    model = provider["models"]["qwen3-coder-30b-a3b"]
    assert model["tool_call"] is True
    assert model["limit"]["context"] > 0
    assert model["limit"]["output"] > 0

    # Compaction settings
    compaction = data.get("compaction", {})
    assert compaction.get("auto") is True
    assert compaction.get("prune") is True
    assert compaction.get("reserved") == 2000

    # 2. Check AGENTS.md rules installed
    agents_file = temp_config_dir / "AGENTS.md"
    assert agents_file.exists()
    content = agents_file.read_text()
    assert "<!-- BEGIN SCAR-VLLM MANAGED RULES -->" in content
    assert "<!-- END SCAR-VLLM MANAGED RULES -->" in content
    assert "Execution discipline" in content
    assert "Post-compaction recovery behavior" in content

    # 3. Check compaction recovery plugin installed
    plugin_file = temp_config_dir / "plugins" / "compaction-recovery.js"
    assert plugin_file.exists()
    plugin_content = plugin_file.read_text()
    assert "experimental.session.compacting" in plugin_content
    assert "CURRENT OBJECTIVE" in plugin_content


def test_idempotency_running_twice(temp_config_dir):
    """Running configure-opencode.sh twice should not alter files or duplicate sections."""
    env = {"OPENCODE_CONFIG_DIR": str(temp_config_dir)}
    run_script(CONFIGURE_SCRIPT, env=env)

    # Record files and state after first run
    config_file = temp_config_dir / "opencode.json"
    agents_file = temp_config_dir / "AGENTS.md"
    plugin_file = temp_config_dir / "plugins" / "compaction-recovery.js"

    config_content_1 = config_file.read_text()
    agents_content_1 = agents_file.read_text()
    plugin_content_1 = plugin_file.read_text()

    # Count backups before second run
    backups_before = list(temp_config_dir.glob("*.bak.*")) + list(temp_config_dir.glob("plugins/*.bak.*"))

    # Second run
    res2 = run_script(CONFIGURE_SCRIPT, env=env)
    assert res2.returncode == 0

    assert config_file.read_text() == config_content_1
    assert agents_file.read_text() == agents_content_1
    assert plugin_file.read_text() == plugin_content_1

    # Ensure no new backups were created on the idempotent run
    backups_after = list(temp_config_dir.glob("*.bak.*")) + list(temp_config_dir.glob("plugins/*.bak.*"))
    assert len(backups_after) == len(backups_before)

    # Verify AGENTS.md marker count is still exactly 1
    assert agents_content_1.count("<!-- BEGIN SCAR-VLLM MANAGED RULES -->") == 1
    assert agents_content_1.count("<!-- END SCAR-VLLM MANAGED RULES -->") == 1


def test_existing_config_with_unrelated_settings(temp_config_dir):
    """Surgical merge should preserve existing unrelated providers, MCP, preferences, and custom rules."""
    config_file = temp_config_dir / "opencode.json"
    initial_config = {
        "$schema": "https://opencode.ai/config.json",
        "username": "developer",
        "provider": {
            "anthropic": {
                "name": "Anthropic Claude",
                "options": {"apiKey": "placeholder-anthropic-key"},  # pragma: allowlist secret
                "models": {"claude-3-7-sonnet": {"name": "Claude 3.7 Sonnet"}}
            }
        },
        "mcp": {
            "custom-mcp": {
                "type": "local",
                "command": ["npx", "-y", "custom-mcp-server"]
            }
        },
        "compaction": {
            "tail_turns": 5
        }
    }
    config_file.write_text(json.dumps(initial_config, indent=2))

    agents_file = temp_config_dir / "AGENTS.md"
    initial_agents_content = "# My Custom Global Rules\n\nAlways use TypeScript.\n"
    agents_file.write_text(initial_agents_content)

    env = {"OPENCODE_CONFIG_DIR": str(temp_config_dir)}
    run_script(CONFIGURE_SCRIPT, env=env)

    # Verify merged JSON
    merged_data = json.loads(config_file.read_text())
    assert merged_data["username"] == "developer"
    assert "anthropic" in merged_data["provider"]
    assert "scar-vllm" in merged_data["provider"]
    assert "custom-mcp" in merged_data["mcp"]
    assert merged_data["compaction"]["tail_turns"] == 5
    assert merged_data["compaction"]["auto"] is True
    assert merged_data["compaction"]["prune"] is True
    assert merged_data["compaction"]["reserved"] == 2000

    # Verify AGENTS.md preserves custom rules
    merged_agents = agents_file.read_text()
    assert "# My Custom Global Rules" in merged_agents
    assert "Always use TypeScript." in merged_agents
    assert "<!-- BEGIN SCAR-VLLM MANAGED RULES -->" in merged_agents
    assert "<!-- END SCAR-VLLM MANAGED RULES -->" in merged_agents


def test_backup_created_when_modifying_existing_file(temp_config_dir):
    """When modifying an existing config, a timestamped backup should be created."""
    config_file = temp_config_dir / "opencode.json"
    config_file.write_text('{"$schema":"https://opencode.ai/config.json"}')

    env = {"OPENCODE_CONFIG_DIR": str(temp_config_dir)}
    run_script(CONFIGURE_SCRIPT, env=env)

    backups = list(temp_config_dir.glob("opencode.json.bak.*"))
    assert len(backups) == 1
    assert backups[0].read_text() == '{"$schema":"https://opencode.ai/config.json"}'


def test_verify_script_success(temp_config_dir):
    """verify-opencode.sh should succeed and exit 0 when configuration is complete."""
    env = {"OPENCODE_CONFIG_DIR": str(temp_config_dir)}
    run_script(CONFIGURE_SCRIPT, env=env)

    verify_res = run_script(VERIFY_SCRIPT, ["--config-dir", str(temp_config_dir)], env=env)
    assert verify_res.returncode == 0
    assert "OpenCode verification succeeded" in verify_res.stdout


def test_verify_script_failure_on_missing_or_invalid(temp_config_dir):
    """verify-opencode.sh should detect missing or invalid configuration and exit non-zero."""
    env = {"OPENCODE_CONFIG_DIR": str(temp_config_dir)}

    # Empty directory -> failure
    res = run_script(VERIFY_SCRIPT, ["--config-dir", str(temp_config_dir)], env=env, check=False)
    assert res.returncode != 0

    # Configure properly
    run_script(CONFIGURE_SCRIPT, env=env)

    # Break compaction settings and verify failure
    config_file = temp_config_dir / "opencode.json"
    data = json.loads(config_file.read_text())
    data["compaction"]["prune"] = False
    config_file.write_text(json.dumps(data, indent=2))

    res_broken = run_script(VERIFY_SCRIPT, ["--config-dir", str(temp_config_dir)], env=env, check=False)
    assert res_broken.returncode != 0
    assert "Tool output pruning is not enabled" in res_broken.stdout


def test_rules_script_status_and_diff(temp_config_dir):
    """Test configure-opencode-rules.sh --status and --diff."""
    env = {"OPENCODE_CONFIG_DIR": str(temp_config_dir)}

    # Status before install -> fails
    status_pre = run_script(CONFIGURE_RULES_SCRIPT, ["--status"], env=env, check=False)
    assert status_pre.returncode != 0

    # Install rules
    run_script(CONFIGURE_RULES_SCRIPT, env=env)

    # Status after install -> passes
    status_post = run_script(CONFIGURE_RULES_SCRIPT, ["--status"], env=env)
    assert status_post.returncode == 0

    # Diff after install -> reports no differences
    diff_res = run_script(CONFIGURE_RULES_SCRIPT, ["--diff"], env=env)
    assert diff_res.returncode == 0
    assert "No differences" in diff_res.stdout


def test_remove_rollback(temp_config_dir):
    """Test rollback via --remove."""
    env = {"OPENCODE_CONFIG_DIR": str(temp_config_dir)}

    # Set up with custom user rules
    agents_file = temp_config_dir / "AGENTS.md"
    agents_file.write_text("# Personal Rules\n\nRule 1.\n")

    run_script(CONFIGURE_SCRIPT, env=env)
    assert "<!-- BEGIN SCAR-VLLM MANAGED RULES -->" in agents_file.read_text()
    assert (temp_config_dir / "plugins" / "compaction-recovery.js").exists()

    # Run --remove
    res_remove = run_script(CONFIGURE_SCRIPT, ["--remove"], env=env)
    assert res_remove.returncode == 0

    # scar-vllm provider removed
    config_file = temp_config_dir / "opencode.json"
    data = json.loads(config_file.read_text())
    assert "scar-vllm" not in data.get("provider", {})

    # Managed rules removed, personal rules preserved
    agents_after = agents_file.read_text()
    assert "<!-- BEGIN SCAR-VLLM MANAGED RULES -->" not in agents_after
    assert "# Personal Rules" in agents_after

    # Plugin removed
    assert not (temp_config_dir / "plugins" / "compaction-recovery.js").exists()


def test_dry_run_leaves_filesystem_untouched(temp_config_dir):
    """Test --dry-run touches nothing."""
    env = {"OPENCODE_CONFIG_DIR": str(temp_config_dir)}
    res = run_script(CONFIGURE_SCRIPT, ["--dry-run"], env=env)
    assert res.returncode == 0
    assert not (temp_config_dir / "opencode.json").exists()
    assert not (temp_config_dir / "AGENTS.md").exists()
    assert not (temp_config_dir / "plugins").exists()
