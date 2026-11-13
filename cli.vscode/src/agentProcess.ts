import * as cp from 'child_process';
import * as readline from 'readline';
import * as path from 'path';
import * as fs from 'fs';
import * as os from 'os';
import * as vscode from 'vscode';
import { EventEmitter } from 'events';

export interface RpcEvent {
  event: string;
  [key: string]: any;
}

export class TealKitAgentProcess extends EventEmitter {
  private process: cp.ChildProcessWithoutNullStreams | null = null;
  private rl: readline.Interface | null = null;
  private isRunning = false;
  private outputChannel: vscode.OutputChannel;
  private lastWorkspaceDir: string = process.cwd();
  private lastMode: string = 'code';

  constructor(outputChannel: vscode.OutputChannel) {
    super();
    this.outputChannel = outputChannel;
  }

  public get active(): boolean {
    return this.isRunning;
  }

  /**
   * Resolves the best available tealkit executable.
   */
  public findCliPath(): string | null {
    const configPath = vscode.workspace.getConfiguration('tealkit').get<string>('cliPath');
    if (configPath && fs.existsSync(configPath)) {
      return configPath;
    }

    const homeDir = os.homedir();
    const candidatePaths = [
      // Standard user installation
      path.join(homeDir, '.tealkitcoder', 'bin', 'tealkit.exe'),
      path.join(homeDir, '.tealkitcoder', 'bin', 'tealkit'),
      // Local repo builds
      path.join(__dirname, '..', '..', 'cli', 'build', 'cli', 'bundle', 'bin', 'tealkit.exe'),
      path.join(__dirname, '..', '..', 'cli', 'tealkit.exe'),
      path.join('c:', 'projects', 'ls', 'mobile_ai_agent', 'cli', 'build', 'cli', 'bundle', 'bin', 'tealkit.exe'),
      path.join('c:', 'projects', 'ls', 'mobile_ai_agent', 'cli', 'tealkit.exe'),
    ];

    for (const p of candidatePaths) {
      if (fs.existsSync(p)) {
        return p;
      }
    }

    return 'tealkit'; // fallback to PATH lookup
  }

  /**
   * Starts the headless agent process.
   */
  public start(workspaceDir: string, initialMode: string = 'code'): void {
    if (this.process) {
      this.dispose();
    }

    this.lastWorkspaceDir = workspaceDir;
    this.lastMode = initialMode;

    const cliPath = this.findCliPath();
    if (!cliPath) {
      vscode.window.showErrorMessage('TealKit CLI binary not found. Please configure "tealkit.cliPath" in settings.');
      return;
    }

    const args = ['rpc', '--workspace', workspaceDir, '--mode', initialMode, '--auto-save-session', '--continue'];

    this.outputChannel.appendLine(`[TealKit] Launching agent: ${cliPath} ${args.join(' ')}`);

    try {
      this.process = cp.spawn(cliPath, args, {
        cwd: workspaceDir,
        env: { ...process.env },
        stdio: ['pipe', 'pipe', 'pipe'],
      });

      this.isRunning = true;

      this.rl = readline.createInterface({
        input: this.process.stdout,
        crlfDelay: Infinity,
      });

      this.rl.on('line', (line: string) => {
        const trimmed = line.trim();
        if (!trimmed) return;
        try {
          const eventObj: RpcEvent = JSON.parse(trimmed);
          this.emit('rpc_event', eventObj);
          if (eventObj.event) {
            this.emit(eventObj.event, eventObj);
          }
        } catch (e) {
          this.outputChannel.appendLine(`[TealKit RAW] ${trimmed}`);
        }
      });

      this.process.stderr.on('data', (data: Buffer) => {
        const text = data.toString();
        this.outputChannel.append(`[TealKit STDERR] ${text}`);
        if (text.includes('Unhandled exception') || text.includes('Exception:') || text.includes('Error:')) {
          this.emit('rpc_event', { event: 'error', message: text.trim() });
        }
      });

      this.process.on('close', (code: number | null) => {
        this.isRunning = false;
        this.outputChannel.appendLine(`[TealKit] Process exited with code ${code}`);
        this.emit('exit', code);
        this.emit('rpc_event', { event: 'process_closed', code });
      });

      this.process.on('error', (err: Error) => {
        this.isRunning = false;
        this.outputChannel.appendLine(`[TealKit ERROR] Process failure: ${err.message}`);
        this.emit('error', err);
        this.emit('rpc_event', { event: 'error', message: `Process failure: ${err.message}` });
      });

    } catch (e: any) {
      this.isRunning = false;
      vscode.window.showErrorMessage(`Failed to start TealKit agent: ${e.message}`);
    }
  }

  public sendCommand(action: string, payload: Record<string, any> = {}): void {
    if (!this.process || !this.isRunning) {
      // Auto-restart if process had stopped
      this.outputChannel.appendLine('[TealKit] Restarting agent on new command...');
      this.start(this.lastWorkspaceDir, this.lastMode);
      setTimeout(() => {
        if (this.process && this.isRunning) {
          const message = JSON.stringify({ action, ...payload }) + '\n';
          this.process.stdin.write(message);
        }
      }, 500);
      return;
    }
    const message = JSON.stringify({ action, ...payload }) + '\n';
    this.process.stdin.write(message);
  }

  public sendPrompt(text: string, images: string[] = []): void {
    this.sendCommand('prompt', { text, prompt: text, images });
  }

  public cancel(): void {
    this.sendCommand('cancel');
  }

  public clearSession(): void {
    this.sendCommand('clear_session');
  }

  public getSessionHistory(): void {
    this.sendCommand('get_session_history');
  }

  public listSessions(): void {
    this.sendCommand('list_sessions');
  }

  public loadSession(filePath: string): void {
    this.sendCommand('load_session', { path: filePath });
  }

  public deleteSession(filePath: string): void {
    this.sendCommand('delete_session', { path: filePath });
  }

  public setMode(mode: string): void {
    this.lastMode = mode;
    this.sendCommand('set_mode', { mode });
  }

  public setModel(model: string): void {
    this.sendCommand('set_model', { model, profile: model });
  }

  public respondPermission(id: string, approved: boolean, always: boolean = false, tool?: string, risk?: string): void {
    this.sendCommand('permission_response', {
      id,
      requestId: id,
      approved,
      allowed: approved,
      always,
      tool,
      risk,
    });
  }

  public getStatus(): void {
    this.sendCommand('get_status');
  }

  public listModels(): void {
    this.sendCommand('list_models');
  }

  public listSkills(): void {
    this.sendCommand('list_skills');
  }

  public attachSkill(name: string): void {
    this.sendCommand('attach_skill', { name, skill: name });
  }

  public detachSkill(name: string): void {
    this.sendCommand('detach_skill', { name, skill: name });
  }

  public archiveMemory(): void {
    this.sendCommand('archive_memory');
  }

  public listWorkflows(): void {
    this.sendCommand('list_workflows');
  }

  public runWorkflow(workflowId: string): void {
    this.sendCommand('run_workflow', { workflowId });
  }

  public listMcpTools(): void {
    this.sendCommand('list_mcp_tools');
  }

  public dispose(): void {
    if (this.rl) {
      this.rl.close();
      this.rl = null;
    }
    if (this.process) {
      try {
        this.sendCommand('exit');
      } catch (_) {}
      this.process.kill();
      this.process = null;
    }
    this.isRunning = false;
  }
}
