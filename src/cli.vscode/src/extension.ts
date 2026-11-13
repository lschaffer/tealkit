import * as vscode from 'vscode';
import * as path from 'path';
import * as fs from 'fs';
import { TealKitAgentProcess } from './agentProcess';
import { TealKitChatViewProvider } from './chatViewProvider';
import { TealKitDiffManager } from './diffManager';
import { TealKitConfigWatcher } from './configWatcher';

let agentProcess: TealKitAgentProcess | null = null;
let statusBarItem: vscode.StatusBarItem;
let configWatcher: TealKitConfigWatcher | null = null;

export function activate(context: vscode.ExtensionContext): void {
  const outputChannel = vscode.window.createOutputChannel('TealKit Coder');
  context.subscriptions.push(outputChannel);

  // Register Diff Provider
  const diffManager = TealKitDiffManager.getInstance();
  context.subscriptions.push(
    vscode.workspace.registerTextDocumentContentProvider(TealKitDiffManager.scheme, diffManager)
  );

  // Create Agent Process
  agentProcess = new TealKitAgentProcess(outputChannel);

  // Status Bar Item
  statusBarItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 100);
  statusBarItem.command = 'tealkit.setMode';
  statusBarItem.text = '$(hubot) TealKit: Ready';
  statusBarItem.tooltip = 'Click to switch TealKit agent mode';
  statusBarItem.show();
  context.subscriptions.push(statusBarItem);

  // Auto-start agent if workspace is open
  const workspaceFolders = vscode.workspace.workspaceFolders;
  const workspaceRoot = workspaceFolders && workspaceFolders.length > 0
    ? workspaceFolders[0].uri.fsPath
    : process.cwd();

  const defaultMode = vscode.workspace.getConfiguration('tealkit').get<string>('defaultMode') || 'code';

  agentProcess.start(workspaceRoot, defaultMode);

  // Listen to status updates to update status bar
  agentProcess.on('ready', (e: any) => {
    statusBarItem.text = `$(hubot) TealKit: ${e.mode || 'code'} [${e.model || 'llm'}]`;
  });

  agentProcess.on('status', (e: any) => {
    statusBarItem.text = `$(hubot) TealKit: ${e.mode || 'code'} [${e.model || 'llm'}]`;
  });

  agentProcess.on('mode_changed', (e: any) => {
    statusBarItem.text = `$(hubot) TealKit: ${e.mode} [${e.model || 'llm'}]`;
  });

  agentProcess.on('model_changed', (e: any) => {
    statusBarItem.text = `$(hubot) TealKit: ${e.mode || 'code'} [${e.model}]`;
  });

  // Register Webview View Provider (retainContextWhenHidden keeps active chat & streaming alive when switching sidebars)
  const chatProvider = new TealKitChatViewProvider(context.extensionUri, agentProcess);
  context.subscriptions.push(
    vscode.window.registerWebviewViewProvider(TealKitChatViewProvider.viewType, chatProvider, {
      webviewOptions: { retainContextWhenHidden: true },
    })
  );

  // Setup configuration file watcher
  configWatcher = new TealKitConfigWatcher(workspaceRoot, agentProcess, chatProvider);
  context.subscriptions.push({ dispose: () => configWatcher?.dispose() });

  // Commands
  context.subscriptions.push(
    vscode.commands.registerCommand('tealkit.startAgent', () => {
      vscode.commands.executeCommand('tealkit.chatView.focus');
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('tealkit.newSession', () => {
      agentProcess?.clearSession();
      chatProvider.clearView();
      vscode.window.showInformationMessage('TealKit: Started new chat session.');
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('tealkit.restart', () => {
      outputChannel.appendLine('[TealKit] Restarting agent process...');
      statusBarItem.text = '$(sync~spin) TealKit: Restarting...';
      agentProcess?.dispose();
      setTimeout(() => {
        agentProcess?.start(workspaceRoot, defaultMode);
        setTimeout(() => {
          agentProcess?.getStatus();
          agentProcess?.listModels();
        }, 500);
        vscode.window.showInformationMessage('TealKit: Agent restarted successfully.');
      }, 300);
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('tealkit.setMode', async () => {
      const mode = await vscode.window.showQuickPick(
        [
          { label: '💻 code', description: 'Implementation & bugfixing with full tool execution' },
          { label: '📐 architect', description: 'Architectural planning, tasks.md drafting (read-only safe)' },
          { label: '💬 ask', description: 'Interactive questions & answers without code changes' },
          { label: '📚 rag', description: 'Knowledge base querying and semantic code search' },
        ],
        { placeHolder: 'Select TealKit Agent Mode' }
      );
      if (mode) {
        const modeKey = mode.label.split(' ')[1];
        agentProcess?.setMode(modeKey);
      }
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('tealkit.selectModel', async () => {
      agentProcess?.listModels();
      vscode.commands.executeCommand('tealkit.chatView.focus');
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('tealkit.openTasks', async () => {
      const tasksPath = path.join(workspaceRoot, 'tasks.md');
      if (!fs.existsSync(tasksPath)) {
        fs.writeFileSync(tasksPath, '# Project Tasks\n\n- [ ] Initial task\n', 'utf-8');
      }
      const doc = await vscode.workspace.openTextDocument(tasksPath);
      await vscode.window.showTextDocument(doc);
    })
  );
}

export function deactivate(): void {
  if (configWatcher) {
    configWatcher.dispose();
    configWatcher = null;
  }
  if (agentProcess) {
    agentProcess.dispose();
    agentProcess = null;
  }
}
