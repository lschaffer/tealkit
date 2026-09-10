import 'package:args/command_runner.dart';

import 'src/commands/auto_discover_command.dart';
import 'src/commands/chat_command.dart';
import 'src/commands/prompt_command.dart';
import 'src/commands/server_command.dart';
import 'src/commands/skill_command.dart';
import 'src/commands/workflow_command.dart';

export 'src/commands/agent_command.dart';
export 'src/commands/auto_discover_command.dart';
export 'src/commands/chat_command.dart';
export 'src/commands/prompt_command.dart';
export 'src/commands/server_command.dart';
export 'src/commands/skill_command.dart';
export 'src/commands/workflow_command.dart';
export 'src/config/env_loader.dart';
export 'src/config/server_config.dart';
export 'src/engine/skill_runner.dart';
export 'src/formatters/terminal_printer.dart';

/// Constructs the primary [CommandRunner] for TealKit CLI.
CommandRunner<void> buildTealKitCommandRunner() {
  final runner = CommandRunner<void>(
    'tealkit',
    'TealKit CLI — Server orchestration, auto-discovery, and direct AgentSkill execution.',
  );

  runner.addCommand(ServerCommand());
  runner.addCommand(PingCommand());
  runner.addCommand(AutoDiscoverCommand());
  runner.addCommand(WorkflowCommand());
  runner.addCommand(SkillCommand());
  runner.addCommand(PromptCommand());
  runner.addCommand(ChatCommand());

  return runner;
}
