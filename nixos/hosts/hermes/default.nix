{
  config,
  pkgs,
  ...
}:

{
  system.stateVersion = "25.11";

  sops = {
    defaultSopsFile = ../../secrets/hermes.yaml;
    secrets = {
      "hermes-env" = {
        key = "hermes_env";
        path = "/run/secrets/hermes-env";
        owner = config.services.hermes-agent.user;
        group = config.services.hermes-agent.group;
        mode = "0400";
      };
      "hermes-auth" = {
        key = "hermes_auth_json";
        path = "/run/secrets/hermes-auth.json";
        owner = config.services.hermes-agent.user;
        group = config.services.hermes-agent.group;
        mode = "0400";
      };
    };
  };

  users.users.root.shell = pkgs.fish;

  # Provision the hermes-agent container's writable layer on first boot
  systemd.services.hermes-agent-container-extras = {
    description = "Install apt + pip packages into the hermes-agent container";
    wants = [ "hermes-agent.service" ];
    after = [ "hermes-agent.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail
      apt_pkgs="docker.io git libopus0"
      npm_pkgs="@openai/codex agent-browser"
      pip_pkgs="supermemory"

      # ubuntu:24.04's default nodejs is 18.19.1; MCP servers and hermes-agent's
      # own mcporter need Node >= 20.11. Pull Node 22 LTS from NodeSource if the
      # current version is too old or missing. Idempotent — skipped when fresh.
      node_major=$(${pkgs.podman}/bin/podman exec hermes-agent bash -c \
        'command -v node >/dev/null 2>&1 && node -p "process.versions.node.split(\".\")[0]"' \
        2>/dev/null || echo 0)
      if [ "$node_major" -lt 20 ]; then
        ${pkgs.podman}/bin/podman exec hermes-agent bash -c \
          'curl -fsSL https://deb.nodesource.com/setup_22.x | bash -'
        ${pkgs.podman}/bin/podman exec hermes-agent apt-get install -y nodejs
      fi

      # apt: install anything missing
      missing_apt=""
      for pkg in $apt_pkgs; do
        if ! ${pkgs.podman}/bin/podman exec hermes-agent dpkg -s "$pkg" >/dev/null 2>&1; then
          missing_apt="$missing_apt $pkg"
        fi
      done
      if [ -n "$missing_apt" ]; then
        ${pkgs.podman}/bin/podman exec hermes-agent apt-get update
        ${pkgs.podman}/bin/podman exec hermes-agent apt-get install -y $missing_apt
      fi

      for pkg in $npm_pkgs; do
        if ! ${pkgs.podman}/bin/podman exec hermes-agent npm list -g "$pkg" >/dev/null 2>&1; then
          ${pkgs.podman}/bin/podman exec hermes-agent npm install -g "$pkg"
        fi
      done

      # pip lives in the uv-managed venv at /home/hermes/.venv that the
      # container entrypoint sets up on first boot. Use its pip explicitly —
      # it's not on root's PATH via `podman exec`.
      venv_pip=/home/hermes/.venv/bin/pip
      venv_bin=/home/hermes/.venv/bin

      # The doctor command expects the editable-install style CLI entrypoint to
      # exist in the managed venv. Hermes itself is supplied outside the venv,
      # and may not be resolvable on PATH during provisioning, so drop a tiny
      # wrapper in place that defers PATH lookup until execution time.
      ${pkgs.podman}/bin/podman exec -u hermes hermes-agent bash -lc '
        set -euo pipefail
        venv_bin=/home/hermes/.venv/bin
        mkdir -p "$venv_bin"
        printf "%s\n" \
          "#!/usr/bin/env bash" \
          "set -euo pipefail" \
          "" \
          "if command -v hermes >/dev/null 2>&1; then" \
          "  exec \"\$(command -v hermes)\" \"\$@\"" \
          "fi" \
          "" \
          "printf \"%s\\n\" \"hermes CLI is not on PATH inside the container\" >&2" \
          "exit 127" \
          > "$venv_bin/hermes"
        chmod 0755 "$venv_bin/hermes"
      '

      # One-time transition cleanup from the Hindsight era. Safe as a no-op once
      # the old packages aren't present on any deployed host.
      ${pkgs.podman}/bin/podman exec -u hermes hermes-agent "$venv_pip" uninstall -y \
        hindsight-client hindsight-api hindsight-api-slim hindsight-embed hindsight-all \
        >/dev/null 2>&1 || true

      for pkg in $pip_pkgs; do
        if ! ${pkgs.podman}/bin/podman exec -u hermes hermes-agent "$venv_pip" show "$pkg" >/dev/null 2>&1; then
          ${pkgs.podman}/bin/podman exec -u hermes hermes-agent "$venv_pip" install "$pkg"
        fi
      done

      # Warm the local Skills Hub state so `hermes doctor` stops reporting the
      # uninitialized directory on freshly bootstrapped hosts.
      ${pkgs.podman}/bin/podman exec -u hermes hermes-agent hermes skills list >/dev/null 2>&1 || true
    '';
  };

  services.hermes-agent = {
    enable = true;
    addToSystemPackages = true;

    container = {
      enable = true;
      backend = "podman";
      image = "ubuntu:24.04";
      # Expose the uv-managed venv's site-packages to hermes-agent's Nix Python.
      # `services.hermes-agent.environment` goes into the agent's config file,
      # not the container process env — so PYTHONPATH has to be injected via
      # podman --env directly.
      extraOptions = [
        "--env"
        "PYTHONPATH=/home/hermes/.venv/lib/python3.11/site-packages"
        "-p"
        "8642:8642"
      ];
    };

    settings = {
      _config_version = 18;

      model = {
        default = "frogbot/kimi-k2-6";
        provider = "llm-proxy";
        base_url = "\${PROXY_API_URL}";
        api_key = "\${PROXY_API_KEY}";
      };

      providers = { };
      fallback_providers = [ ];
      credential_pool_strategies = { };

      custom_providers = [
        {
          name = "llm-proxy";
          base_url = "\${PROXY_API_URL}";
          api_key = "\${PROXY_API_KEY}";
        }
      ];

      toolsets = [ "hermes-cli" ];

      platform_toolsets = {
        cli = [
          "browser"
          "clarify"
          "code_execution"
          "cronjob"
          "delegation"
          "file"
          "image_gen"
          "memory"
          "session_search"
          "skills"
          "terminal"
          "todo"
          "tts"
          "vision"
          "web"
        ];
        telegram = [ "hermes-telegram" ];
        discord = [ "hermes-discord" ];
        whatsapp = [ "hermes-whatsapp" ];
        slack = [ "hermes-slack" ];
        signal = [ "hermes-signal" ];
        homeassistant = [ "hermes-homeassistant" ];
        qqbot = [ "hermes-qqbot" ];
      };

      agent = {
        max_turns = 90;
        gateway_timeout = 1800;
        gateway_timeout_warning = 900;
        gateway_notify_interval = 600;
        restart_drain_timeout = 60;
        service_tier = "";
        tool_use_enforcement = "auto";
        verbose = false;
        reasoning_effort = "medium";
        system_prompt = "You are a creative assistant. Think outside the box and offer innovative solutions.";
        personalities = {
          helpful = "You are a helpful, friendly AI assistant.";
          concise = "You are a concise assistant. Keep responses brief and to the point.";
          technical = "You are a technical expert. Provide detailed, accurate technical information.";
          creative = "You are a creative assistant. Think outside the box and offer innovative solutions.";
          teacher = "You are a patient teacher. Explain concepts clearly with examples.";
        };
      };

      terminal = {
        backend = "local";
        modal_mode = "auto";
        cwd = ".";
        timeout = 180;
        env_passthrough = [ ];
        docker_image = "nikolaik/python-nodejs:python3.11-nodejs20";
        docker_forward_env = [ ];
        docker_env = { };
        singularity_image = "docker://nikolaik/python-nodejs:python3.11-nodejs20";
        modal_image = "nikolaik/python-nodejs:python3.11-nodejs20";
        daytona_image = "nikolaik/python-nodejs:python3.11-nodejs20";
        container_cpu = 1;
        container_memory = 5120;
        container_disk = 51200;
        container_persistent = true;
        docker_volumes = [ ];
        docker_mount_cwd_to_workspace = false;
        persistent_shell = true;
        lifetime_seconds = 300;
      };

      browser = {
        inactivity_timeout = 120;
        command_timeout = 30;
        record_sessions = false;
        allow_private_urls = false;
        camofox = {
          managed_persistence = false;
        };
        cloud_provider = "local";
      };

      checkpoints = {
        enabled = true;
        max_snapshots = 50;
      };

      file_read_max_chars = 100000;

      compression = {
        enabled = true;
        threshold = 0.5;
        target_ratio = 0.2;
        protect_last_n = 20;
      };

      smart_model_routing = {
        enabled = true;
        max_simple_chars = 160;
        max_simple_words = 28;
        cheap_model = {
          provider = "openai";
          model = "openai/gpt-5.4-mini";
        };
      };

      auxiliary =
        let
          auto = {
            provider = "auto";
            model = "";
            base_url = "";
            api_key = "";
            timeout = 120;
          };
        in
        {
          vision = auto // {
            download_timeout = 30;
          };
          web_extract = auto // {
            timeout = 360;
          };
          compression = auto;
          session_search = auto // {
            timeout = 30;
          };
          skills_hub = auto // {
            timeout = 30;
          };
          approval = auto // {
            timeout = 30;
          };
          mcp = auto // {
            timeout = 30;
          };
          flush_memories = auto;
        };

      display = {
        compact = false;
        personality = "concise";
        resume_display = "full";
        busy_input_mode = "interrupt";
        bell_on_complete = false;
        show_reasoning = false;
        streaming = true;
        inline_diffs = true;
        show_cost = false;
        skin = "default";
        interim_assistant_messages = true;
        tool_progress_command = false;
        tool_progress_overrides = { };
        tool_preview_length = 0;
        tool_progress = "all";
        background_process_notifications = "all";
      };

      privacy = {
        redact_pii = false;
      };

      tts = {
        provider = "edge";
        edge = {
          voice = "en-US-AriaNeural";
        };
        elevenlabs = {
          voice_id = "pNInz6obpgDQGcFmaJgB";
          model_id = "eleven_multilingual_v2";
        };
        openai = {
          model = "gpt-4o-mini-tts";
          voice = "alloy";
        };
        mistral = {
          model = "voxtral-mini-tts-2603";
          voice_id = "c69964a6-ab8b-4f8a-9465-ec0925096ec8";
        };
        neutts = {
          ref_audio = "";
          ref_text = "";
          model = "neuphonic/neutts-air-q4-gguf";
          device = "cpu";
        };
      };

      stt = {
        enabled = true;
        provider = "local";
        local = {
          model = "base";
          language = "";
        };
        openai = {
          model = "whisper-1";
        };
        mistral = {
          model = "voxtral-mini-latest";
        };
      };

      voice = {
        record_key = "ctrl+b";
        max_recording_seconds = 120;
        auto_tts = false;
        silence_threshold = 200;
        silence_duration = 3.0;
      };

      human_delay = {
        mode = "off";
        min_ms = 800;
        max_ms = 2500;
      };

      context = {
        engine = "compressor";
      };

      memory = {
        memory_enabled = true;
        user_profile_enabled = true;
        skill_generation = true;
        episodic_archive  = true;
        memory_char_limit = 3000;
        user_char_limit = 2000;
        provider = "supermemory";
        nudge_interval = 10;
        flush_min_turns = 6;
      };

      delegation = {
        model = "";
        provider = "";
        base_url = "";
        api_key = "";
        max_iterations = 50;
        max_concurrent_children = 5;
        max_spawn_depth = 2;
        orchestrator_enabled = true;
        reasoning_effort = "";
        default_toolsets = [
          "terminal"
          "file"
          "web"
        ];
      };

      prefill_messages_file = "";

      skills = {
        external_dirs = [ ];
        creation_nudge_interval = 15;
      };

      honcho = { };

      timezone = "";

      discord = {
        require_mention = false;
        free_response_channels = "";
        allowed_channels = "";
        auto_thread = true;
        reactions = true;
      };

      whatsapp = { };

      approvals = {
        mode = "manual";
        timeout = 60;
      };

      command_allowlist = [ ];
      quick_commands = { };
      personalities = { };

      security = {
        redact_secrets = true;
        tirith_enabled = true;
        tirith_path = "tirith";
        tirith_timeout = 5;
        tirith_fail_open = true;
        website_blocklist = {
          enabled = false;
          domains = [ ];
          shared_files = [ ];
        };
      };

      cron = {
        wrap_response = true;
      };

      logging = {
        level = "INFO";
        max_size_mb = 5;
        backup_count = 3;
      };

      network = {
        force_ipv4 = false;
      };

      session_reset = {
        mode = "both";
        idle_minutes = 1440;
        at_hour = 4;
      };
      group_sessions_per_user = true;

      streaming = {
        enabled = false;
      };

      code_execution = {
        timeout = 300;
        max_tool_calls = 50;
      };

      web = {
        backend = "exa";
      };
    };

    environment = {
      LANG = "C.UTF-8";
      LC_ALL = "C.UTF-8";

      # Terminal / browser tool knobs
      TERMINAL_MODAL_IMAGE = "nikolaik/python-nodejs:python3.11-nodejs20";
      TERMINAL_TIMEOUT = "180";
      TERMINAL_LIFETIME_SECONDS = "300";
      BROWSERBASE_PROXIES = "true";
      BROWSERBASE_ADVANCED_STEALTH = "false";
      BROWSER_SESSION_TIMEOUT = "300";
      BROWSER_INACTIVITY_TIMEOUT = "120";

      # Debug toggles
      WEB_TOOLS_DEBUG = "false";
      VISION_TOOLS_DEBUG = "false";
      MOA_TOOLS_DEBUG = "false";
      IMAGE_TOOLS_DEBUG = "false";

      # Agent limits
      HERMES_MAX_ITERATIONS = "90";

      # Discord
      DISCORD_BOT_TOKEN = "\${DISCORD_BOT_TOKEN}";
      DISCORD_ALLOWED_USERS = "\${DISCORD_ALLOWED_USERS}";
      DISCORD_HOME_CHANNEL = "\${DISCORD_HOME_CHANNEL}";
      DISCORD_REQUIRE_MENTION = "false";

      # API server (non-secret — key is in sops)
      API_SERVER_ENABLED = "true";
      API_SERVER_HOST = "0.0.0.0";
    };

    environmentFiles = [ config.sops.secrets."hermes-env".path ];
    authFile = config.sops.secrets."hermes-auth".path;
  };

  # Supermemory provider config. The hermes-agent NixOS module only templates
  # config.yaml; per-plugin configs live next to it under $HERMES_HOME and are
  # not covered by services.hermes-agent.settings. Symlink keeps it declarative.
  # SUPERMEMORY_API_KEY is supplied via the sops-backed hermes-env file.
  systemd.tmpfiles.settings."10-hermes-supermemory" = {
    "/var/lib/hermes/.hermes/supermemory.json"."L+" = {
      argument = toString (
        pkgs.writeText "supermemory.json" (
          builtins.toJSON {
            container_tag = "hermes_primary";
            auto_recall = true;
            auto_capture = true;
            max_recall_results = 10;
            profile_frequency = 50;
            capture_mode = "all";
            search_mode = "hybrid";
            api_timeout = 5.0;
          }
        )
      );
    };
  };

  # API server on 8642 is exposed only to the LAN. Auth is enforced by
  # API_SERVER_KEY (sops-managed in hermes-env); the firewall scope is
  # defense-in-depth, not the primary control.
  networking.firewall.extraInputRules = ''
    ip saddr 10.0.1.0/24 tcp dport 8642 accept
  '';
}
