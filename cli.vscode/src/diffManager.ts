import * as vscode from 'vscode';
import * as path from 'path';
import * as fs from 'fs';

export class TealKitDiffManager implements vscode.TextDocumentContentProvider {
  public static readonly scheme = 'tealkit-diff';
  private static instance: TealKitDiffManager;

  private onDidChangeEmitter = new vscode.EventEmitter<vscode.Uri>();
  public readonly onDidChange = this.onDidChangeEmitter.event;

  private memoryFiles = new Map<string, string>();

  public static getInstance(): TealKitDiffManager {
    if (!TealKitDiffManager.instance) {
      TealKitDiffManager.instance = new TealKitDiffManager();
    }
    return TealKitDiffManager.instance;
  }

  public provideTextDocumentContent(uri: vscode.Uri): string {
    return this.memoryFiles.get(uri.toString()) || '';
  }

  /**
   * Opens side-by-side diff editor showing current vs proposed content.
   */
  public async showDiff(
    filePath: string,
    originalContent: string,
    modifiedContent: string
  ): Promise<void> {
    const baseName = path.basename(filePath);
    const originalUri = vscode.Uri.parse(
      `${TealKitDiffManager.scheme}:/original/${baseName}?ref=${encodeURIComponent(filePath)}&v=orig`
    );
    const modifiedUri = vscode.Uri.parse(
      `${TealKitDiffManager.scheme}:/modified/${baseName}?ref=${encodeURIComponent(filePath)}&v=mod`
    );

    this.memoryFiles.set(originalUri.toString(), originalContent);
    this.memoryFiles.set(modifiedUri.toString(), modifiedContent);

    this.onDidChangeEmitter.fire(originalUri);
    this.onDidChangeEmitter.fire(modifiedUri);

    await vscode.commands.executeCommand(
      'vscode.diff',
      originalUri,
      modifiedUri,
      `${baseName} (TealKit Diff)`
    );
  }

  /**
   * Applies the proposed modified content directly to disk using VS Code WorkspaceEdit.
   */
  public async applyDiff(filePath: string, modifiedContent: string): Promise<boolean> {
    try {
      let targetUri: vscode.Uri;
      if (path.isAbsolute(filePath)) {
        targetUri = vscode.Uri.file(filePath);
      } else {
        const workspaceFolders = vscode.workspace.workspaceFolders;
        if (!workspaceFolders || workspaceFolders.length === 0) {
          throw new Error('No workspace folder open');
        }
        targetUri = vscode.Uri.file(path.join(workspaceFolders[0].uri.fsPath, filePath));
      }

      const fileDir = path.dirname(targetUri.fsPath);
      if (!fs.existsSync(fileDir)) {
        fs.mkdirSync(fileDir, { recursive: true });
      }

      const fileExists = fs.existsSync(targetUri.fsPath);
      const wsEdit = new vscode.WorkspaceEdit();

      if (!fileExists) {
        wsEdit.createFile(targetUri, { overwrite: true, ignoreIfExists: false });
        wsEdit.insert(targetUri, new vscode.Position(0, 0), modifiedContent);
      } else {
        const doc = await vscode.workspace.openTextDocument(targetUri);
        const fullRange = new vscode.Range(
          doc.positionAt(0),
          doc.positionAt(doc.getText().length)
        );
        wsEdit.replace(targetUri, fullRange, modifiedContent);
      }

      const applied = await vscode.workspace.applyEdit(wsEdit);
      if (applied) {
        const doc = await vscode.workspace.openTextDocument(targetUri);
        await doc.save();
        vscode.window.showInformationMessage(`TealKit: Applied changes to ${path.basename(filePath)}`);
        return true;
      }
      return false;
    } catch (e: any) {
      vscode.window.showErrorMessage(`Failed to apply changes to ${filePath}: ${e.message}`);
      return false;
    }
  }

  public clear(): void {
    this.memoryFiles.clear();
  }
}
