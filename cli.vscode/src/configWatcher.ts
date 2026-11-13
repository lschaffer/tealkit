import * as vscode from 'vscode';
import * as path from 'path';
import * as os from 'os';
import { TealKitAgentProcess } from './agentProcess';
import { TealKitChatViewProvider } from './chatViewProvider';

export class TealKitConfigWatcher {
  private disposables: vscode.Disposable[] = [];

  constructor(
    private readonly workspaceRoot: string,
    private readonly agent: TealKitAgentProcess,
    private readonly chatProvider?: TealKitChatViewProvider
  ) {
    this.setupWatchers();
  }

  private setupWatchers(): void {
    // Watch workspace tasks.md, tealkit_agent.md, AGENTS.md, *.yaml
    const pattern = new vscode.RelativePattern(this.workspaceRoot, '{tasks.md,tealkit_agent.md,AGENTS.md,*.yaml}');
    const watcher = vscode.workspace.createFileSystemWatcher(pattern);

    watcher.onDidChange((uri) => this.onFileChanged(uri));
    watcher.onDidCreate((uri) => this.onFileChanged(uri));
    this.disposables.push(watcher);

    // Watch global config directory ~/.tealkitcoder/
    const homeDir = os.homedir();
    const globalPattern = new vscode.RelativePattern(
      path.join(homeDir, '.tealkitcoder'),
      '*.{yaml,md}'
    );
    const globalWatcher = vscode.workspace.createFileSystemWatcher(globalPattern);
    globalWatcher.onDidChange((uri) => this.onFileChanged(uri));
    this.disposables.push(globalWatcher);
  }

  private onFileChanged(uri: vscode.Uri): void {
    const fileName = path.basename(uri.fsPath).toLowerCase();
    if (fileName.includes('config') || fileName.includes('permissions')) {
      this.agent.sendCommand('reload_config');
      this.chatProvider?.refreshConfigsFromDisk('config');
    } else if (fileName.includes('llm')) {
      this.agent.listModels();
      this.agent.getStatus();
      this.chatProvider?.refreshConfigsFromDisk('llm');
    } else if (fileName.includes('mcp') || fileName.includes('tools')) {
      this.agent.sendCommand('reload_mcp');
      this.agent.listMcpTools();
      this.chatProvider?.refreshConfigsFromDisk('mcp');
    } else if (fileName.includes('server')) {
      this.chatProvider?.refreshConfigsFromDisk('server');
    }
  }

  public dispose(): void {
    for (const d of this.disposables) {
      d.dispose();
    }
    this.disposables = [];
  }
}

