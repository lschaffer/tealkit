import * as cp from 'child_process';
import * as vscode from 'vscode';
import * as path from 'path';
import { TealKitAgentProcess, RpcEvent } from './agentProcess';
import { TealKitDiffManager } from './diffManager';
import {
  TealKitYamlConfigManager,
  LlmProfileItem,
  McpServerItem,
  ServerProfileItem,
  SkillItem,
  MemoryArchiveItem,
} from './yamlConfigManager';

export class TealKitChatViewProvider implements vscode.WebviewViewProvider {
  public static readonly viewType = 'tealkit.chatView';
  private _view?: vscode.WebviewView;
  private _activeSkills: string[] = [];

  constructor(
    private readonly _extensionUri: vscode.Uri,
    private readonly _agent: TealKitAgentProcess
  ) {
    this.registerAgentListeners();
  }

  public clearView(): void {
    this._view?.webview.postMessage({ type: 'clear' });
  }

  public refreshConfigsFromDisk(kind?: 'config' | 'llm' | 'mcp' | 'server'): void {
    if (!this._view) return;
    if (!kind || kind === 'config') {
      const config = TealKitYamlConfigManager.loadCliConfig();
      this._view.webview.postMessage({ type: 'cli_config_data', ...config });
    }
    if (!kind || kind === 'llm') {
      const llmConfig = TealKitYamlConfigManager.loadLlmConfig();
      this._view.webview.postMessage({ type: 'llm_config_data', ...llmConfig });
    }
    if (!kind || kind === 'mcp') {
      const mcpConfig = TealKitYamlConfigManager.loadMcpConfig();
      this._view.webview.postMessage({ type: 'mcp_config_data', ...mcpConfig });
    }
    if (!kind || kind === 'server') {
      const serverConfig = TealKitYamlConfigManager.loadServerConfig();
      this._view.webview.postMessage({ type: 'server_config_data', ...serverConfig });
      this._agent.listWorkflows();
    }
  }

  public resolveWebviewView(
    webviewView: vscode.WebviewView,
    _context: vscode.WebviewViewResolveContext,
    _token: vscode.CancellationToken
  ): void {
    this._view = webviewView;

    webviewView.webview.options = {
      enableScripts: true,
      localResourceRoots: [this._extensionUri],
    };

    webviewView.webview.html = this._getHtmlForWebview(webviewView.webview);

    webviewView.webview.onDidReceiveMessage(async (message: any) => {
      switch (message.type) {
        case 'prompt':
          this._agent.sendPrompt(message.text, message.images || []);
          break;
        case 'cancel':
          this._agent.cancel();
          break;
        case 'clear':
          this._agent.clearSession();
          break;
        case 'set_mode':
          this._agent.setMode(message.mode);
          break;
        case 'set_model':
          this._agent.setModel(message.model);
          break;
        case 'permission_response':
          this._agent.respondPermission(message.id, message.approved, message.always, message.tool, message.risk);
          break;
        case 'apply_diff':
          if (message.path && message.modified !== undefined) {
            const success = await TealKitDiffManager.getInstance().applyDiff(message.path, message.modified);
            if (success) {
              this._view?.webview.postMessage({
                type: 'diff_applied',
                path: message.path,
                id: message.id,
              });
            }
          }
          break;
        case 'review_diff':
          if (message.path && message.original !== undefined && message.modified !== undefined) {
            await TealKitDiffManager.getInstance().showDiff(message.path, message.original, message.modified);
          }
          break;
        case 'open_tasks':
          vscode.commands.executeCommand('tealkit.openTasks');
          break;
        case 'open_settings':
          vscode.commands.executeCommand('workbench.action.openSettings', 'tealkit');
          break;
        case 'restart_agent':
          vscode.commands.executeCommand('tealkit.restart');
          break;
        case 'get_cli_config': {
          const config = TealKitYamlConfigManager.loadCliConfig();
          this._view?.webview.postMessage({
            type: 'cli_config_data',
            ...config,
          });
          break;
        }
        case 'save_cli_config': {
          if (message.config) {
            TealKitYamlConfigManager.saveCliConfig(message.config);
            this._agent.sendCommand('reload_config');
            const updated = TealKitYamlConfigManager.loadCliConfig();
            this._view?.webview.postMessage({
              type: 'cli_config_data',
              ...updated,
              savedAt: new Date().toLocaleTimeString(),
            });
            if (!message.silent) {
              vscode.window.showInformationMessage('TealKit Coder settings saved & reloaded.');
            }
          }
          break;
        }
        case 'open_config_file': {
          const cfgPath = TealKitYamlConfigManager.getCliConfigPath();
          if (cfgPath) {
            try {
              const doc = await vscode.workspace.openTextDocument(vscode.Uri.file(cfgPath));
              await vscode.window.showTextDocument(doc);
            } catch (e: any) {
              vscode.window.showErrorMessage(`Could not open config file: ${e.message}`);
            }
          }
          break;
        }
        case 'ready_request': {
          this._agent.getStatus();
          this._agent.listModels();
          this._agent.listSkills();
          this._agent.getSessionHistory();
          this._agent.listSessions();
          const cliCfg = TealKitYamlConfigManager.loadCliConfig();
          this._view?.webview.postMessage({
            type: 'cli_config_data',
            ...cliCfg,
          });
          break;
        }
        case 'get_session_history': {
          this._agent.getSessionHistory();
          break;
        }
        case 'list_sessions': {
          this._agent.listSessions();
          break;
        }
        case 'load_session': {
          if (message.path) {
            this._agent.loadSession(message.path);
          }
          break;
        }
        case 'delete_session': {
          if (message.path) {
            this._agent.deleteSession(message.path);
          }
          break;
        }
        case 'new_session': {
          this._agent.clearSession();
          this._agent.listSessions();
          break;
        }

        // LLM YAML Config Management
        case 'get_llm_config': {
          const config = TealKitYamlConfigManager.loadLlmConfig();
          this._view?.webview.postMessage({
            type: 'llm_config_data',
            ...config,
          });
          break;
        }
        case 'save_llm_profile': {
          if (message.profile) {
            TealKitYamlConfigManager.saveLlmProfile(message.profile, message.isDefault, message.originalName);
            this._agent.listModels();
            if (message.isDefault) {
              this._agent.setModel(message.profile.name);
            }
            const config = TealKitYamlConfigManager.loadLlmConfig();
            this._view?.webview.postMessage({
              type: 'llm_config_data',
              ...config,
            });
            vscode.window.showInformationMessage(`Saved LLM profile: ${message.profile.name}`);
          }
          break;
        }
        case 'delete_llm_profile': {
          if (message.name) {
            TealKitYamlConfigManager.deleteLlmProfile(message.name);
            this._agent.listModels();
            const config = TealKitYamlConfigManager.loadLlmConfig();
            this._view?.webview.postMessage({
              type: 'llm_config_data',
              ...config,
            });
            vscode.window.showInformationMessage(`Deleted LLM profile: ${message.name}`);
          }
          break;
        }
        case 'test_llm_api': {
          const { provider, model, baseUrl, apiKey } = message;
          const result = await this.testLlmApiConnection(provider, model, baseUrl, apiKey);
          this._view?.webview.postMessage({
            type: 'test_llm_api_result',
            ...result,
          });
          break;
        }
        case 'fetch_provider_models': {
          const { provider, baseUrl, apiKey } = message;
          const result = await this.fetchProviderModelsList(provider, baseUrl, apiKey);
          this._view?.webview.postMessage({
            type: 'fetch_provider_models_result',
            ...result,
          });
          break;
        }
        case 'set_default_llm_profile': {
          if (message.name) {
            TealKitYamlConfigManager.setDefaultLlmProfile(message.name);
            this._agent.listModels();
            const config = TealKitYamlConfigManager.loadLlmConfig();
            this._view?.webview.postMessage({
              type: 'llm_config_data',
              ...config,
            });
          }
          break;
        }

        // MCP YAML Config Management
        case 'get_mcp_config': {
          const config = TealKitYamlConfigManager.loadMcpConfig();
          this._view?.webview.postMessage({
            type: 'mcp_config_data',
            ...config,
          });
          break;
        }
        case 'save_mcp_server': {
          if (message.server) {
            TealKitYamlConfigManager.saveMcpServer(message.server, message.originalName);
            this._agent.sendCommand('reload_mcp');
            const config = TealKitYamlConfigManager.loadMcpConfig();
            this._view?.webview.postMessage({
              type: 'mcp_config_data',
              ...config,
            });
            vscode.window.showInformationMessage(`Saved MCP server: ${message.server.name}`);
          }
          break;
        }
        case 'delete_mcp_server': {
          if (message.name) {
            TealKitYamlConfigManager.deleteMcpServer(message.name);
            this._agent.sendCommand('reload_mcp');
            const config = TealKitYamlConfigManager.loadMcpConfig();
            this._view?.webview.postMessage({
              type: 'mcp_config_data',
              ...config,
            });
            vscode.window.showInformationMessage(`Deleted MCP server: ${message.name}`);
          }
          break;
        }
        case 'toggle_mcp_server': {
          if (message.name !== undefined && message.enabled !== undefined) {
            TealKitYamlConfigManager.toggleMcpServer(message.name, message.enabled);
            this._agent.sendCommand('reload_mcp');
            const config = TealKitYamlConfigManager.loadMcpConfig();
            this._view?.webview.postMessage({
              type: 'mcp_config_data',
              ...config,
            });
          }
          break;
        }
        case 'test_mcp_server': {
          if (message.server) {
            const res = await this.testMcpServerTools(message.server);
            this._view?.webview.postMessage({
              type: 'test_mcp_server_result',
              serverName: message.server.name,
              fromModal: !!message.fromModal,
              ...res,
            });
          }
          break;
        }

        // Skills Management
        case 'get_skills': {
          const skillsData = TealKitYamlConfigManager.loadSkillsList(this._activeSkills);
          this._view?.webview.postMessage({
            type: 'skills_data',
            ...skillsData,
            activeSkills: this._activeSkills,
          });
          this._agent.listSkills();
          break;
        }
        case 'attach_skill': {
          if (message.name) {
            if (!this._activeSkills.includes(message.name)) {
              this._activeSkills.push(message.name);
            }
            this._agent.attachSkill(message.name);
            const skillsData = TealKitYamlConfigManager.loadSkillsList(this._activeSkills);
            this._view?.webview.postMessage({
              type: 'skills_data',
              ...skillsData,
              activeSkills: this._activeSkills,
            });
            vscode.window.showInformationMessage(`Attached skill: ${message.name}`);
          }
          break;
        }
        case 'detach_skill': {
          if (message.name) {
            this._activeSkills = this._activeSkills.filter((s) => s !== message.name);
            this._agent.detachSkill(message.name);
            const skillsData = TealKitYamlConfigManager.loadSkillsList(this._activeSkills);
            this._view?.webview.postMessage({
              type: 'skills_data',
              ...skillsData,
              activeSkills: this._activeSkills,
            });
            vscode.window.showInformationMessage(`Detached skill: ${message.name}`);
          }
          break;
        }
        case 'save_skill': {
          if (message.name && message.content) {
            TealKitYamlConfigManager.saveSkillFile(message.name, message.content);
            const skillsData = TealKitYamlConfigManager.loadSkillsList(this._activeSkills);
            this._view?.webview.postMessage({
              type: 'skills_data',
              ...skillsData,
              activeSkills: this._activeSkills,
            });
            vscode.window.showInformationMessage(`Saved skill: ${message.name}`);
          }
          break;
        }

        // Memory Archive Management
        case 'archive_memory': {
          this._agent.archiveMemory();
          break;
        }
        case 'get_memory_archives': {
          const archives = TealKitYamlConfigManager.loadMemoryArchives();
          this._view?.webview.postMessage({
            type: 'memory_archives_data',
            archives,
          });
          break;
        }

        // Server & Scheduled Workflows
        case 'get_server_config': {
          const serverConfig = TealKitYamlConfigManager.loadServerConfig();
          this._view?.webview.postMessage({
            type: 'server_config_data',
            ...serverConfig,
          });
          this._agent.listWorkflows();
          break;
        }
        case 'save_server_profile': {
          if (message.profile) {
            TealKitYamlConfigManager.saveServerProfile(message.profile, message.originalName);
            const serverConfig = TealKitYamlConfigManager.loadServerConfig();
            this._view?.webview.postMessage({
              type: 'server_config_data',
              ...serverConfig,
            });
            this._agent.listWorkflows();
            vscode.window.showInformationMessage(`Saved server profile: ${message.profile.name}`);
          }
          break;
        }
        case 'delete_server_profile': {
          if (message.name) {
            TealKitYamlConfigManager.deleteServerProfile(message.name);
            const serverConfig = TealKitYamlConfigManager.loadServerConfig();
            this._view?.webview.postMessage({
              type: 'server_config_data',
              ...serverConfig,
            });
            this._agent.listWorkflows();
          }
          break;
        }
        case 'activate_server_profile': {
          if (message.name) {
            TealKitYamlConfigManager.activateServerProfile(message.name);
            const serverConfig = TealKitYamlConfigManager.loadServerConfig();
            this._view?.webview.postMessage({
              type: 'server_config_data',
              ...serverConfig,
            });
            this._agent.listWorkflows();
          }
          break;
        }
        case 'test_server_connection': {
          const res = await this.testServerConnection(message.url, message.apiKey);
          this._view?.webview.postMessage({
            type: 'test_server_connection_result',
            profileName: message.name || '',
            fromModal: !!message.fromModal,
            ...res,
          });
          break;
        }
        case 'list_workflows': {
          this._agent.listWorkflows();
          break;
        }
        case 'run_workflow': {
          if (message.id) {
            this._agent.runWorkflow(message.id);
            vscode.window.showInformationMessage(`Triggered workflow: ${message.name || message.id}`);
          }
          break;
        }
        case 'get_workflow_status': {
          if (message.id) {
            this._agent.sendCommand('get_workflow_status', { workflowId: message.id });
          }
          break;
        }
        case 'get_workflow_logs': {
          if (message.id) {
            this._agent.sendCommand('get_workflow_logs', { workflowId: message.id });
          }
          break;
        }
        case 'cancel_workflow': {
          if (message.id) {
            this._agent.sendCommand('cancel_workflow', { workflowId: message.id });
          }
          break;
        }

        // Open config file directly in VS Code editor
        case 'open_file': {
          if (message.filePath) {
            try {
              const doc = await vscode.workspace.openTextDocument(vscode.Uri.file(message.filePath));
              await vscode.window.showTextDocument(doc);
            } catch (e: any) {
              vscode.window.showErrorMessage(`Could not open file: ${e.message}`);
            }
          }
          break;
        }
      }
    });
  }

  private registerAgentListeners(): void {
    this._agent.on('rpc_event', (event: RpcEvent) => {
      this._view?.webview.postMessage({
        type: 'agent_event',
        event: event,
      });

      if (event.event === 'skills_changed' && event.activeSkills) {
        this._activeSkills = event.activeSkills;
        this._view?.webview.postMessage({
          type: 'skills_changed',
          activeSkills: this._activeSkills,
        });
      }

      if ((event.event === 'ready' || event.event === 'status') && event.activeSkills) {
        this._activeSkills = event.activeSkills;
      }

      if (event.event === 'memory_archived') {
        const archives = TealKitYamlConfigManager.loadMemoryArchives();
        this._view?.webview.postMessage({
          type: 'memory_archives_data',
          archives,
        });
      }

      // Optionally auto-open native diff editor if configured
      if (event.event === 'diff' && event.path && event.original !== undefined && event.modified !== undefined) {
        const autoPreview = vscode.workspace.getConfiguration('tealkit').get<boolean>('autoPreviewDiff', true);
        if (autoPreview) {
          TealKitDiffManager.getInstance().showDiff(event.path, event.original, event.modified);
        }
      }
    });
  }

  public postMessage(msg: any): void {
    this._view?.webview.postMessage(msg);
  }

  private async testLlmApiConnection(
    provider?: string,
    model?: string,
    baseUrl?: string,
    apiKey?: string
  ): Promise<{ success: boolean; latencyMs?: number; message: string }> {
    const startTime = Date.now();
    try {
      const p = (provider || 'openai_compatible').toLowerCase();
      const effectiveBase = (baseUrl || '').trim().replace(/\/+$/, '');
      const key = (apiKey || '').trim();

      if (p === 'ollama') {
        const url = effectiveBase || 'http://localhost:11434';
        const res = await fetch(`${url}/api/tags`, { signal: AbortSignal.timeout(8000) });
        const latencyMs = Date.now() - startTime;
        if (res.ok) {
          return { success: true, latencyMs, message: `Connected to Ollama (${latencyMs}ms)` };
        } else {
          return { success: false, message: `Ollama returned HTTP ${res.status}: ${res.statusText}` };
        }
      }

      if (p === 'anthropic') {
        const url = effectiveBase || 'https://api.anthropic.com/v1';
        const res = await fetch(`${url}/messages`, {
          method: 'POST',
          headers: {
            'content-type': 'application/json',
            'x-api-key': key,
            'anthropic-version': '2023-06-01',
          },
          body: JSON.stringify({
            model: model || 'claude-3-5-sonnet-20241022',
            max_tokens: 1,
            messages: [{ role: 'user', content: 'hi' }],
          }),
          signal: AbortSignal.timeout(10000),
        });
        const latencyMs = Date.now() - startTime;
        if (res.ok) {
          return { success: true, latencyMs, message: `Connected to Anthropic (${latencyMs}ms)` };
        } else {
          const errText = await res.text().catch(() => '');
          return { success: false, message: `Anthropic HTTP ${res.status}: ${errText.substring(0, 150)}` };
        }
      }

      // OpenAI-compatible / DeepSeek / Mistral / Groq
      let endpoint = effectiveBase;
      if (!endpoint) {
        if (p === 'deepseek') endpoint = 'https://api.deepseek.com/v1';
        else if (p === 'mistral') endpoint = 'https://api.mistral.ai/v1';
        else if (p === 'groq') endpoint = 'https://api.groq.com/openai/v1';
        else endpoint = 'https://api.openai.com/v1';
      }

      let chatUrl = endpoint;
      if (!chatUrl.endsWith('/chat/completions')) {
        chatUrl = `${chatUrl}/chat/completions`;
      }

      const headers: Record<string, string> = {
        'content-type': 'application/json',
      };
      if (key) {
        headers['Authorization'] = `Bearer ${key}`;
      }

      const testModel = model || 'gpt-4o-mini';
      const res = await fetch(chatUrl, {
        method: 'POST',
        headers,
        body: JSON.stringify({
          model: testModel,
          messages: [{ role: 'user', content: 'hi' }],
          max_tokens: 1,
        }),
        signal: AbortSignal.timeout(12000),
      });

      const latencyMs = Date.now() - startTime;
      if (res.ok) {
        return { success: true, latencyMs, message: `Connected successfully (${latencyMs}ms)` };
      } else {
        const body = await res.text().catch(() => '');
        let errMsg = `HTTP ${res.status}: ${res.statusText}`;
        try {
          const parsed = JSON.parse(body);
          if (parsed.error?.message) errMsg += ` - ${parsed.error.message}`;
          else if (parsed.message) errMsg += ` - ${parsed.message}`;
        } catch (_) {
          if (body) errMsg += ` - ${body.substring(0, 120)}`;
        }
        return { success: false, message: errMsg };
      }
    } catch (e: any) {
      return { success: false, message: e.name === 'TimeoutError' ? 'Connection timed out (12s)' : e.message };
    }
  }

  private async fetchProviderModelsList(
    provider?: string,
    baseUrl?: string,
    apiKey?: string
  ): Promise<{ success: boolean; models?: string[]; error?: string }> {
    try {
      const p = (provider || 'openai_compatible').toLowerCase();
      const effectiveBase = (baseUrl || '').trim().replace(/\/+$/, '');
      const key = (apiKey || '').trim();

      if (p === 'ollama') {
        const url = effectiveBase || 'http://localhost:11434';
        const res = await fetch(`${url}/api/tags`, { signal: AbortSignal.timeout(8000) });
        if (!res.ok) throw new Error(`Ollama returned HTTP ${res.status}`);
        const data: any = await res.json();
        const models = (data.models || []).map((m: any) => m.name || m.model).filter(Boolean);
        return { success: true, models };
      }

      let modelsUrl = effectiveBase;
      if (!modelsUrl) {
        if (p === 'deepseek') modelsUrl = 'https://api.deepseek.com/v1';
        else if (p === 'mistral') modelsUrl = 'https://api.mistral.ai/v1';
        else if (p === 'groq') modelsUrl = 'https://api.groq.com/openai/v1';
        else modelsUrl = 'https://api.openai.com/v1';
      }

      modelsUrl = modelsUrl.replace(/\/chat\/completions$/, '');
      if (!modelsUrl.endsWith('/models')) {
        modelsUrl = `${modelsUrl}/models`;
      }

      const headers: Record<string, string> = {};
      if (key) {
        headers['Authorization'] = `Bearer ${key}`;
      }

      const res = await fetch(modelsUrl, { headers, signal: AbortSignal.timeout(10000) });
      if (!res.ok) {
        const errText = await res.text().catch(() => '');
        throw new Error(`HTTP ${res.status}: ${errText.substring(0, 120)}`);
      }

      const data: any = await res.json();
      let models: string[] = [];
      if (Array.isArray(data.data)) {
        models = data.data.map((m: any) => m.id).filter(Boolean);
      } else if (Array.isArray(data)) {
        models = data.map((m: any) => m.id || m.name).filter(Boolean);
      } else if (Array.isArray(data.models)) {
        models = data.models.map((m: any) => m.id || m.name).filter(Boolean);
      }

      models.sort();
      return { success: true, models };
    } catch (e: any) {
      return { success: false, error: e.name === 'TimeoutError' ? 'Timeout fetching models' : e.message };
    }
  }

  private async testServerConnection(
    rawUrl?: string,
    rawApiKey?: string
  ): Promise<{ success: boolean; latencyMs?: number; workflowsCount?: number; message: string }> {
    const startTime = Date.now();
    const baseUrl = (rawUrl || '').trim().replace(/\/+$/, '');
    if (!baseUrl) {
      return { success: false, message: 'Server URL is required.' };
    }
    try {
      const headers: Record<string, string> = { 'Content-Type': 'application/json' };
      const apiKey = (rawApiKey || '').trim();
      if (apiKey) {
        headers['Authorization'] = `Bearer ${apiKey}`;
      }
      const healthRes = await fetch(`${baseUrl}/health`, {
        headers,
        signal: AbortSignal.timeout(8000),
      });
      if (!healthRes.ok) {
        return {
          success: false,
          message: `Health check failed (HTTP ${healthRes.status}: ${healthRes.statusText})`,
        };
      }
      let workflowsCount: number | undefined;
      try {
        const tasksRes = await fetch(`${baseUrl}/api/v1/tasks`, {
          headers,
          signal: AbortSignal.timeout(8000),
        });
        if (tasksRes.ok) {
          const data: any = await tasksRes.json();
          if (Array.isArray(data?.tasks)) {
            workflowsCount = data.tasks.length;
          }
        } else if (tasksRes.status === 401 || tasksRes.status === 403) {
          return {
            success: false,
            message: `Server reachable, but API key rejected (HTTP ${tasksRes.status})`,
          };
        }
      } catch (_) {}
      const latencyMs = Date.now() - startTime;
      const wfInfo = workflowsCount !== undefined ? `, ${workflowsCount} workflows available` : '';
      return {
        success: true,
        latencyMs,
        workflowsCount,
        message: `Connected (${latencyMs}ms${wfInfo})`,
      };
    } catch (e: any) {
      return {
        success: false,
        message: e.name === 'TimeoutError' ? 'Connection timed out (8s)' : `Connection failed: ${e.message}`,
      };
    }
  }

  private async testMcpServerTools(
    server: McpServerItem
  ): Promise<{ success: boolean; tools?: Array<{ name: string; description: string }>; error?: string }> {
    return new Promise((resolve) => {
      try {
        const rawCmd = (server.command || '').trim();
        if (!rawCmd) {
          resolve({ success: false, error: 'Command is empty.' });
          return;
        }
        const cmdParts = rawCmd.split(/\s+/).filter(Boolean);
        const exe = cmdParts[0];
        const extraArgs = cmdParts.slice(1);
        const allArgs = [...extraArgs, ...(server.args || [])];

        const childEnv: Record<string, string> = {};
        for (const [k, v] of Object.entries(process.env)) {
          if (v !== undefined) childEnv[k] = v;
        }
        if (server.env && typeof server.env === 'object') {
          for (const [k, v] of Object.entries(server.env)) {
            if (v !== undefined && v !== null && String(v).trim() !== '') {
              childEnv[k] = String(v);
            }
          }
        }

        const proc = cp.spawn(exe, allArgs, {
          env: childEnv,
          shell: true,
          stdio: ['pipe', 'pipe', 'pipe'],
        });

        let resolved = false;
        let stderrBuf = '';
        let stdoutBuf = '';

        const finish = (res: { success: boolean; tools?: Array<{ name: string; description: string }>; error?: string }) => {
          if (resolved) return;
          resolved = true;
          clearTimeout(timer);
          try {
            proc.kill();
          } catch (_) {}
          resolve(res);
        };

        const timer = setTimeout(() => {
          finish({
            success: false,
            error: `Timed out after 15s waiting for MCP tools list.${stderrBuf ? ' Stderr: ' + stderrBuf.trim().slice(0, 200) : ''}`,
          });
        }, 15000);

        proc.on('error', (err) => {
          finish({ success: false, error: `Failed to spawn process: ${err.message}` });
        });

        proc.stderr.on('data', (chunk: Buffer) => {
          stderrBuf += chunk.toString();
        });

        proc.stdout.on('data', (chunk: Buffer) => {
          stdoutBuf += chunk.toString();
          const lines = stdoutBuf.split(/\r?\n/);
          stdoutBuf = lines.pop() || '';
          for (const line of lines) {
            const trimmed = line.trim();
            if (!trimmed.startsWith('{')) continue;
            try {
              const msg = JSON.parse(trimmed);
              if (msg.id === 1 && msg.result) {
                const initNotif = JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n';
                const listReq = JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'tools/list', params: {} }) + '\n';
                proc.stdin.write(initNotif + listReq);
              } else if (msg.id === 2 && msg.result) {
                const rawTools = Array.isArray(msg.result.tools) ? msg.result.tools : [];
                const tools = rawTools.map((t: any) => ({
                  name: String(t.name || ''),
                  description: String(t.description || ''),
                }));
                finish({ success: true, tools });
              } else if (msg.error) {
                finish({ success: false, error: msg.error.message || JSON.stringify(msg.error) });
              }
            } catch (_) {}
          }
        });

        proc.on('close', (code) => {
          if (!resolved) {
            finish({
              success: false,
              error: `Process exited (code ${code}) before returning tools.${stderrBuf ? ' ' + stderrBuf.trim().slice(0, 200) : ''}`,
            });
          }
        });

        const initReq =
          JSON.stringify({
            jsonrpc: '2.0',
            id: 1,
            method: 'initialize',
            params: {
              protocolVersion: '2024-11-05',
              capabilities: {},
              clientInfo: { name: 'tealkit-vscode', version: '0.1.4' },
            },
          }) + '\n';
        proc.stdin.write(initReq);
      } catch (e: any) {
        resolve({ success: false, error: e.message || String(e) });
      }
    });
  }

  private _getHtmlForWebview(webview: vscode.Webview): string {
    const scriptUri = webview.asWebviewUri(vscode.Uri.joinPath(this._extensionUri, 'media', 'chat.js'));
    const styleUri = webview.asWebviewUri(vscode.Uri.joinPath(this._extensionUri, 'media', 'chat.css'));

    return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>TealKit Agent</title>
  <link rel="stylesheet" href="${styleUri}">
</head>
<body>
  <div class="tealkit-container">
    <!-- Header / Status Bar -->
    <div class="header">
      <div class="status-row">
        <div class="brand">
          <span class="brand-dot"></span>
          <span class="agent-title">TealKit Coder</span>
        </div>
        <div class="header-badges">
          <span id="tools-badge" class="badge-mini" title="Active Tools">0 tools</span>
          <span id="agent-status-badge" class="badge">Connecting...</span>
          <button id="restart-agent-btn" class="gear-btn" title="Restart Agent Process">🔄</button>
          
        </div>
      </div>

      <!-- Navigation Tabs -->
      <div class="tabs-nav">
        <button id="tab-btn-chat" class="tab-btn active" data-tab="chat">💬 Chat</button>
        <button id="tab-btn-llms" class="tab-btn" data-tab="llms">🤖 LLMs</button>
        <button id="tab-btn-mcp" class="tab-btn" data-tab="mcp">🔌 MCP Tools</button>
        <button id="tab-btn-skills" class="tab-btn" data-tab="skills">🧩 Skills</button>
        <button id="tab-btn-memory" class="tab-btn" data-tab="memory">🧠 Memory</button>
        <button id="tab-btn-server" class="tab-btn" data-tab="server">☁️ Server</button>
        <button id="tab-btn-settings" class="tab-btn" data-tab="settings">⚙ Settings</button>
      </div>
    </div>

    <!-- TAB 1: Chat View -->
    <div id="panel-chat" class="tab-panel active">
      <div class="controls-row">
        <select id="mode-select" class="dropdown mode-select" title="Agent Mode">
          <option value="code">💻 Code</option>
          <option value="architect">📐 Architect / Plan</option>
          <option value="ask">💬 Ask</option>
          <option value="rag">📚 RAG</option>
        </select>
        <select id="model-select" class="dropdown model-select" title="LLM Profile">
          <option value="">(Loading models...)</option>
        </select>
      </div>

      <!-- Attached Skills Bar in Chat -->
      <div id="attached-skills-bar" class="attached-skills-bar">
        <span class="attached-label">Skills:</span>
        <div id="attached-skills-chips" class="attached-skills-chips">
          <span class="no-skills-text">(none attached)</span>
        </div>
        <button id="quick-attach-btn" class="mini-chip-btn" title="Attach Skill to session">+ Attach</button>
      </div>

      <!-- Message Thread -->
      <div id="messages" class="messages-container">
        <div class="welcome-box">
          <h4>👋 Welcome to TealKit Coder</h4>
          <p>Your workspace coding agent is ready. Ask questions, build features, run tests, or plan implementations.</p>
          <div class="quick-actions">
            <button class="quick-btn" onclick="sendQuickPrompt('/plan ')">📐 /plan</button>
            <button class="quick-btn" onclick="sendQuickPrompt('Check project structure and tasks')">🔍 Inspect</button>
            <button class="quick-btn" onclick="openTasksFile()">📋 tasks.md</button>
          </div>
        </div>
      </div>

      <!-- Active Sub-Agent / Tool Indicator -->
      <div id="activity-indicator" class="activity-bar hidden">
        <div class="spinner"></div>
        <span id="activity-text">Agent is thinking...</span>
        <button id="cancel-btn" class="cancel-btn" title="Cancel operation">✕ Cancel</button>
      </div>

      <!-- Input Footer -->
      <div class="input-area">
        <div class="textarea-container">
          <textarea id="prompt-input" rows="2" placeholder="Ask TealKit or use /plan, /rag, /skills... (Ctrl+Enter to send)"></textarea>
        </div>
        <div class="input-actions">
          <div class="input-left">
            <button id="new-session-btn" class="icon-btn" title="New Session (Start fresh chat)">➕</button>
            <button id="history-btn" class="icon-btn" title="Session History (Load / Continue saved sessions)">🕒</button>
            <button id="clear-btn" class="icon-btn" title="Clear Session">🧹</button>
            <button id="tasks-btn" class="icon-btn" title="Open tasks.md">📋</button>
          </div>
          <button id="send-btn" class="send-btn">Send ↵</button>
        </div>
      </div>
    </div>

    <!-- TAB 2: LLM Configuration Panel -->
    <div id="panel-llms" class="tab-panel hidden">
      <div class="config-banner">
        <div class="config-path-box">
          <span class="config-label">Source:</span>
          <span id="llm-file-path" class="config-path" title="Config file path">loading...</span>
        </div>
        <button id="open-llm-file-btn" class="mini-btn" title="Open in VS Code Editor">📄 Open</button>
      </div>

      <div class="panel-actions-bar">
        <span class="panel-section-title">Configured LLM Profiles</span>
        <div class="panel-btn-group">
          <button id="add-llm-btn" class="primary-btn-sm">+ Add Profile</button>
          <button id="refresh-llm-btn" class="icon-btn-sm" title="Refresh">🔄</button>
        </div>
      </div>

      <div id="llm-list" class="cards-list">
        <div class="loading-state">Loading LLM profiles...</div>
      </div>
    </div>

    <!-- TAB 3: MCP Servers Panel -->
    <div id="panel-mcp" class="tab-panel hidden">
      <div class="config-banner">
        <div class="config-path-box">
          <span class="config-label">Source:</span>
          <span id="mcp-file-path" class="config-path" title="Config file path">loading...</span>
        </div>
        <button id="open-mcp-file-btn" class="mini-btn" title="Open in VS Code Editor">📄 Open</button>
      </div>

      <div class="panel-actions-bar">
        <span class="panel-section-title">External MCP Servers</span>
        <div class="panel-btn-group">
          <button id="add-mcp-btn" class="primary-btn-sm">+ Add Server</button>
          <button id="refresh-mcp-btn" class="icon-btn-sm" title="Refresh">🔄</button>
        </div>
      </div>

      <div id="mcp-list" class="cards-list">
        <div class="loading-state">Loading MCP servers...</div>
      </div>
    </div>

    <!-- TAB 4: Skills Panel (pic2) -->
    <div id="panel-skills" class="tab-panel hidden">
      <div class="config-banner">
        <div class="config-path-box">
          <span class="config-label">Skills Dir:</span>
          <span id="skills-dir-path" class="config-path" title="Skills folder">loading...</span>
        </div>
        <button id="open-skills-folder-btn" class="mini-btn" title="Open folder">📁 Open</button>
      </div>

      <div class="panel-actions-bar">
        <span class="panel-section-title">Available Agent Skills</span>
        <div class="panel-btn-group">
          <button id="add-skill-btn" class="primary-btn-sm">+ New Skill</button>
          <button id="refresh-skills-btn" class="icon-btn-sm" title="Refresh">🔄</button>
        </div>
      </div>

      <div id="skills-list" class="cards-list">
        <div class="loading-state">Loading skills...</div>
      </div>
    </div>

    <!-- TAB 5: Memory Archive Panel (pic1) -->
    <div id="panel-memory" class="tab-panel hidden">
      <div class="memory-header-box">
        <div class="memory-title-row">
          <span class="memory-icon">🧠</span>
          <span class="memory-heading">Memory Archive</span>
        </div>
        <p class="memory-desc">
          Past conversation turns are automatically compressed into episodic memory. The agent can recall past architecture decisions and solutions via <code>retrieve_memory</code>.
        </p>
      </div>

      <div class="panel-actions-bar">
        <span class="panel-section-title">Saved Chat Sessions (.tealkit/sessions)</span>
        <div class="panel-btn-group">
          <button id="memory-new-session-btn" class="primary-btn-sm" title="Start a new chat session">+ New Session</button>
          <button id="refresh-sessions-btn" class="icon-btn-sm" title="Refresh Sessions">🔄</button>
        </div>
      </div>

      <div id="saved-sessions-list" class="cards-list" style="max-height: 240px; margin-bottom: 12px;">
        <div class="loading-state">Loading saved chat sessions...</div>
      </div>

      <div class="panel-actions-bar">
        <span class="panel-section-title">Archived Episodic Memories</span>
        <div class="panel-btn-group">
          <button id="archive-now-btn" class="primary-btn-sm" title="Archive active turns now">🧠 Archive Now</button>
          <button id="refresh-memory-btn" class="icon-btn-sm" title="Refresh">🔄</button>
        </div>
      </div>

      <div id="memory-list" class="cards-list">
        <div class="loading-state">Loading memory archives...</div>
      </div>
    </div>

    <!-- TAB 6: Server & Scheduled Workflows Panel -->
    <div id="panel-server" class="tab-panel hidden">
      <div class="config-banner">
        <div class="config-path-box">
          <span class="config-label">server.yaml:</span>
          <span id="server-config-path" class="config-path">loading...</span>
        </div>
        <button id="open-server-file-btn" class="mini-btn" title="Open server.yaml">📄 Open</button>
      </div>

      <div class="panel-actions-bar">
        <span class="panel-section-title">TealKit Server Profiles</span>
        <div class="panel-btn-group">
          <button id="add-server-btn" class="primary-btn-sm">+ Add Profile</button>
          <button id="refresh-server-btn" class="icon-btn-sm" title="Refresh">🔄</button>
        </div>
      </div>

      <div id="server-profiles-list" class="cards-list">
        <div class="loading-state">Loading server profiles...</div>
      </div>

      <div class="panel-actions-bar" style="margin-top: 14px;">
        <span class="panel-section-title">Remote Scheduled Workflows</span>
        <button id="refresh-workflows-btn" class="icon-btn-sm" title="Refresh Workflows">🔄</button>
      </div>

      <div id="workflows-list" class="cards-list">
        <div class="loading-state">Loading workflows from server...</div>
      </div>
    </div>

    <!-- TAB 7: Generic CLI Settings Panel -->
    <div id="panel-settings" class="tab-panel hidden">
      <div class="config-banner">
        <div class="config-path-box">
          <span class="config-label">config.yaml:</span>
          <span id="cli-config-path" class="config-path">loading...</span>
        </div>
        <div style="display: flex; gap: 4px;">
          <button id="reload-config-btn" class="mini-btn" title="Reload config.yaml from disk">🔄 Reload</button>
          <button id="open-config-file-btn" class="mini-btn" title="Open config.yaml">📄 Open</button>
        </div>
      </div>

      <div class="settings-form-container">
        <div id="cfg-save-status" class="hint-status" style="margin-bottom: 4px;"></div>

        <div class="settings-section-card">
          <div class="section-card-title">Execution & Session Limits</div>
          <div class="form-row-2col">
            <div class="form-group">
              <label for="cfg-max-turns">Max Session Turns</label>
              <input type="number" id="cfg-max-turns" min="1" max="5000" value="500" />
            </div>
            <div class="form-group">
              <label for="cfg-max-size-mb">Max Session Size (MB)</label>
              <input type="number" id="cfg-max-size-mb" min="1" max="500" value="10" />
            </div>
          </div>
          <div class="form-row-2col">
            <div class="form-group">
              <label for="cfg-max-tool-iterations">Max Tool Iterations</label>
              <input type="number" id="cfg-max-tool-iterations" min="1" max="500" value="100" />
            </div>
            <div class="form-group">
              <label for="cfg-progressive-tools">Progressive Tool Discovery</label>
              <select id="cfg-progressive-tools">
                <option value="auto">auto</option>
                <option value="on">on</option>
                <option value="off">off</option>
              </select>
            </div>
          </div>
          <div class="form-group-checkbox">
            <label>
              <input type="checkbox" id="cfg-auto-save" checked />
              <span>Auto-Save Session History (<code>session.auto_save</code>)</span>
            </label>
          </div>
        </div>

        <div class="settings-section-card">
          <div class="section-card-title">Context, Planning & Prompt</div>
          <div class="form-row-2col">
            <div class="form-group">
              <label for="cfg-compression-threshold">Compression Threshold (tokens)</label>
              <input type="number" id="cfg-compression-threshold" min="500" max="100000" step="500" value="4000" />
            </div>
            <div class="form-group">
              <label for="cfg-submit-key">CLI Submit Key</label>
              <select id="cfg-submit-key">
                <option value="enter">enter</option>
                <option value="ctrl-enter">ctrl-enter</option>
                <option value="double-enter">double-enter</option>
              </select>
            </div>
          </div>
          <div class="form-group-checkbox">
            <label>
              <input type="checkbox" id="cfg-planning" checked />
              <span>Enable Planning Phase (<code>agent.planning</code>)</span>
            </label>
          </div>
          <div class="form-group-checkbox">
            <label>
              <input type="checkbox" id="cfg-compact-tools" checked />
              <span>Compact Tool Schemas (<code>compact_tools</code>)</span>
            </label>
          </div>
          <div class="form-group-checkbox">
            <label>
              <input type="checkbox" id="cfg-multiline" />
              <span>Multiline CLI Prompt Input (<code>prompt.multiline</code>)</span>
            </label>
          </div>
          <div class="form-group-checkbox">
            <label>
              <input type="checkbox" id="cfg-auto-paste-images" checked />
              <span>Auto-Paste Clipboard Images (<code>prompt.auto_paste_images</code>)</span>
            </label>
          </div>
        </div>

        <div class="settings-section-card">
          <div class="section-card-title">Tool Auto-Approval Checks</div>
          <div class="form-group-checkbox">
            <label>
              <input type="checkbox" id="cfg-perm-read" checked />
              <span>Auto-Approve Read Tools (<code>permissions.auto_approve_read</code>)</span>
            </label>
          </div>
          <div class="form-group-checkbox">
            <label>
              <input type="checkbox" id="cfg-perm-write" />
              <span>Auto-Approve Write / File Edit Tools (<code>permissions.auto_approve_write</code>)</span>
            </label>
          </div>
          <div class="form-group-checkbox">
            <label>
              <input type="checkbox" id="cfg-perm-execute" />
              <span>Auto-Approve Terminal Execution (<code>permissions.auto_approve_execute</code>)</span>
            </label>
          </div>
          <div class="form-group-checkbox">
            <label>
              <input type="checkbox" id="cfg-perm-network" />
              <span>Auto-Approve Network / Web Tools (<code>permissions.auto_approve_network</code>)</span>
            </label>
          </div>
        </div>

        <div class="settings-section-card">
          <div class="section-card-title">RAG (Retrieval-Augmented Generation) Settings</div>
          <div class="form-group-checkbox" style="margin-bottom: 8px;">
            <label>
              <input type="checkbox" id="cfg-rag-enabled" checked />
              <span>Enable Local RAG Indexing & Search (<code>rag.enabled</code>)</span>
            </label>
          </div>
          <div class="form-group">
            <label for="cfg-rag-db-path">Index Database Path</label>
            <input type="text" id="cfg-rag-db-path" placeholder="rag_index.db" />
          </div>
          <div class="form-group">
            <label for="cfg-rag-folders">Folder Sources (one path per line)</label>
            <textarea id="cfg-rag-folders" rows="2" placeholder="Leave empty or add local documentation directories..."></textarea>
          </div>
          <div class="form-group">
            <label for="cfg-rag-web">Web Sources (one URL per line)</label>
            <textarea id="cfg-rag-web" rows="2" placeholder="Leave empty or add documentation URLs..."></textarea>
          </div>
          <div class="form-row-2col">
            <div class="form-group">
              <label for="cfg-rag-max-pages">Max Crawl Pages</label>
              <input type="number" id="cfg-rag-max-pages" min="1" max="1000" value="50" />
            </div>
            <div class="form-group">
              <label for="cfg-rag-extensions">File Extensions (comma-sep)</label>
              <input type="text" id="cfg-rag-extensions" value=".txt, .md, .pdf, .docx, .csv, .json" />
            </div>
          </div>
          <div class="form-row-2col">
            <div class="form-group">
              <label for="cfg-rag-chunk-size">Chunk Size</label>
              <input type="number" id="cfg-rag-chunk-size" min="100" max="8000" step="50" value="1000" />
            </div>
            <div class="form-group">
              <label for="cfg-rag-chunk-overlap">Chunk Overlap</label>
              <input type="number" id="cfg-rag-chunk-overlap" min="0" max="2000" step="25" value="150" />
            </div>
          </div>
          <div class="form-row-2col">
            <div class="form-group">
              <label for="cfg-rag-embed-provider">Embedding Provider</label>
              <select id="cfg-rag-embed-provider">
                <option value="embedded">embedded</option>
                <option value="openai_compatible">openai_compatible</option>
                <option value="ollama">ollama</option>
                <option value="gemini">gemini</option>
                <option value="mistral">mistral</option>
              </select>
            </div>
            <div class="form-group">
              <label for="cfg-rag-embed-model">Embedding Model</label>
              <input type="text" id="cfg-rag-embed-model" placeholder="nomic-embed-text-v1.5.Q4_K_M.gguf" />
            </div>
          </div>
          <div class="form-row-2col">
            <div class="form-group">
              <label for="cfg-rag-embed-baseurl">Embedding Base URL</label>
              <input type="text" id="cfg-rag-embed-baseurl" placeholder="http://localhost:11434" />
            </div>
            <div class="form-group">
              <label for="cfg-rag-embed-gpulayers">Embedding GPU Layers</label>
              <input type="number" id="cfg-rag-embed-gpulayers" min="0" max="128" value="0" />
            </div>
          </div>
          <div class="form-group">
            <label for="cfg-rag-embed-apikey">Embedding API Key (optional)</label>
            <input type="password" id="cfg-rag-embed-apikey" placeholder="Leave blank if not required" />
          </div>
          <div class="form-row-3col">
            <div class="form-group">
              <label for="cfg-rag-search-mode">Search Mode</label>
              <select id="cfg-rag-search-mode">
                <option value="hybrid">hybrid</option>
                <option value="fts">fts</option>
                <option value="semantic">semantic</option>
              </select>
            </div>
            <div class="form-group">
              <label for="cfg-rag-max-chunks">Max Chunks</label>
              <input type="number" id="cfg-rag-max-chunks" min="1" max="50" value="5" />
            </div>
            <div class="form-group">
              <label for="cfg-rag-min-score">Min Score</label>
              <input type="number" id="cfg-rag-min-score" min="0" max="1" step="0.05" value="0.15" />
            </div>
          </div>
        </div>

        <div style="padding: 6px 0;">
          <button id="btn-save-cli-settings" class="primary-btn" style="width: 100%;">💾 Save & Sync Settings</button>
        </div>
      </div>
    </div>
  </div>

  <!-- LLM Modal Dialog -->
  <div id="llm-modal" class="modal-overlay hidden">
    <div class="modal-content">
      <div class="modal-header">
        <h3 id="llm-modal-title">Configure LLM Profile</h3>
        <button id="llm-modal-close" class="close-btn">✕</button>
      </div>
      <div class="modal-body">
        <div class="form-group">
          <label for="llm-input-name">Profile Name *</label>
          <input type="text" id="llm-input-name" placeholder="e.g. deepinfra_qwen3-coder" />
        </div>
        <div class="form-group">
          <label for="llm-input-provider">Provider</label>
          <select id="llm-input-provider">
            <option value="openai_compatible">openai_compatible</option>
            <option value="deepseek">deepseek</option>
            <option value="mistral">mistral</option>
            <option value="gemini">gemini</option>
            <option value="anthropic">anthropic</option>
            <option value="ollama">ollama</option>
            <option value="groq">groq</option>
            <option value="custom">custom</option>
          </select>
        </div>
        <div class="form-group">
          <div class="label-with-action">
            <label for="llm-input-model">Model ID *</label>
            <button type="button" id="llm-btn-load-models" class="mini-action-btn" title="Query provider models list">&#128269; Load Models</button>
          </div>
          <input type="text" id="llm-input-model" list="llm-model-datalist" placeholder="e.g. Qwen/Qwen2.5-Coder-32B-Instruct" />
          <datalist id="llm-model-datalist"></datalist>
          <div id="llm-models-status" class="hint-status"></div>
        </div>
        <div class="form-group">
          <label for="llm-input-baseurl">Base URL (optional)</label>
          <input type="text" id="llm-input-baseurl" placeholder="e.g. https://api.deepinfra.com/v1/openai" />
        </div>
        <div class="form-group">
          <label for="llm-input-apikey">API Key (optional if in ENV)</label>
          <div class="input-with-eye">
            <input type="password" id="llm-input-apikey" placeholder="Enter API Key or leave blank" />
            <button type="button" id="toggle-apikey-visibility" class="eye-btn" title="Toggle visibility">👁</button>
          </div>
        </div>
        <div class="form-row-2col">
          <div class="form-group">
            <label for="llm-input-temp">Temperature</label>
            <input type="number" id="llm-input-temp" step="0.05" min="0" max="2" placeholder="0.2" />
          </div>
          <div class="form-group">
            <label for="llm-input-maxtokens">Max Tokens</label>
            <input type="number" id="llm-input-maxtokens" step="256" min="256" max="32768" placeholder="8192" />
          </div>
        </div>
        <div class="form-row-3col">
          <div class="form-group">
            <label for="llm-input-context-size">Context Size</label>
            <input type="number" id="llm-input-context-size" step="1024" placeholder="e.g. 131072" />
          </div>
          <div class="form-group">
            <label for="llm-input-topp">Top P</label>
            <input type="number" id="llm-input-topp" step="0.05" min="0" max="1" placeholder="0.95" />
          </div>
          <div class="form-group">
            <label for="llm-input-topk">Top K</label>
            <input type="number" id="llm-input-topk" step="1" min="1" max="200" placeholder="40" />
          </div>
        </div>
        <div class="form-group">
          <label for="llm-input-repeat-penalty">Repeat Penalty</label>
          <input type="number" id="llm-input-repeat-penalty" step="0.05" min="0" max="2" placeholder="1.0" />
        </div>
        <div class="form-group checkbox-group">
          <input type="checkbox" id="llm-input-isslm" />
          <label for="llm-input-isslm">SLM Mode (Optimize prompts for smaller models)</label>
        </div>
        <div class="form-group checkbox-group">
          <input type="checkbox" id="llm-input-thinking" />
          <label for="llm-input-thinking">Thinking / Reasoning Mode</label>
        </div>
        <div class="form-group checkbox-group">
          <input type="checkbox" id="llm-input-streaming" />
          <label for="llm-input-streaming">Use Streaming Responses</label>
        </div>
        <div class="form-group checkbox-group">
          <input type="checkbox" id="llm-input-default" />
          <label for="llm-input-default">Set as default model</label>
        </div>
        <div id="llm-test-result" class="test-result-badge"></div>
      </div>
      <div class="modal-footer">
        <button type="button" id="llm-btn-test-api" class="secondary-btn">🔌 Test API</button>
        <button id="llm-modal-cancel" class="secondary-btn">Cancel</button>
        <button id="llm-modal-save" class="primary-btn">Save Profile</button>
      </div>
    </div>
  </div>

  <!-- MCP Modal Dialog -->
  <div id="mcp-modal" class="modal-overlay hidden">
    <div class="modal-content">
      <div class="modal-header">
        <h3 id="mcp-modal-title">Configure MCP Server</h3>
        <button id="mcp-modal-close" class="close-btn">✕</button>
      </div>
      <div class="modal-body">
        <div class="form-group">
          <label for="mcp-input-name">Server Name *</label>
          <input type="text" id="mcp-input-name" placeholder="e.g. filesystem" />
        </div>
        <div class="form-group">
          <label for="mcp-input-command">Command *</label>
          <input type="text" id="mcp-input-command" placeholder="e.g. npx, uvx, node, docker" />
        </div>
        <div class="form-group">
          <label for="mcp-input-args">Arguments (space separated)</label>
          <input type="text" id="mcp-input-args" placeholder="-y @modelcontextprotocol/server-filesystem c:/projects" />
        </div>
        <div class="form-group">
          <label for="mcp-input-env">Environment Variables (JSON)</label>
          <textarea id="mcp-input-env" rows="3" placeholder='{"API_KEY": "xxx"}'></textarea>
        </div>
        <div class="form-group checkbox-group">
          <input type="checkbox" id="mcp-input-enabled" checked />
          <label for="mcp-input-enabled">Enabled</label>
        </div>
        <div id="mcp-modal-tools-result" class="mcp-tools-preview hidden"></div>
      </div>
      <div class="modal-footer">
        <button type="button" id="mcp-btn-test" class="secondary-btn" title="Spawn MCP server and list its tools">🔍 Test / Show Tools</button>
        <button id="mcp-modal-cancel" class="secondary-btn">Cancel</button>
        <button id="mcp-modal-save" class="primary-btn">Save Server</button>
      </div>
    </div>
  </div>

  <!-- Skill Modal Dialog -->
  <div id="skill-modal" class="modal-overlay hidden">
    <div class="modal-content">
      <div class="modal-header">
        <h3 id="skill-modal-title">Create New Skill</h3>
        <button id="skill-modal-close" class="close-btn">✕</button>
      </div>
      <div class="modal-body">
        <div class="form-group">
          <label for="skill-input-name">Skill Name *</label>
          <input type="text" id="skill-input-name" placeholder="e.g. dotnet-engineer-skill" />
        </div>
        <div class="form-group">
          <label for="skill-input-desc">Description</label>
          <input type="text" id="skill-input-desc" placeholder="Brief description of the skill" />
        </div>
        <div class="form-group">
          <label for="skill-input-prompt">System Prompt / Instructions</label>
          <textarea id="skill-input-prompt" rows="5" placeholder="You are an expert engineer..."></textarea>
        </div>
      </div>
      <div class="modal-footer">
        <button id="skill-modal-cancel" class="secondary-btn">Cancel</button>
        <button id="skill-modal-save" class="primary-btn">Save Skill</button>
      </div>
    </div>
  </div>

  <!-- Server Profile Modal Dialog -->
  <div id="server-modal" class="modal-overlay hidden">
    <div class="modal-content">
      <div class="modal-header">
        <h3 id="server-modal-title">Configure Server Profile</h3>
        <button id="server-modal-close" class="close-btn">✕</button>
      </div>
      <div class="modal-body">
        <div class="form-group">
          <label for="server-input-name">Profile Name *</label>
          <input type="text" id="server-input-name" placeholder="e.g. Local Server" />
        </div>
        <div class="form-group">
          <label for="server-input-url">Server URL *</label>
          <input type="text" id="server-input-url" placeholder="http://localhost:7771" />
        </div>
        <div class="form-group">
          <label for="server-input-apikey">API Key (optional)</label>
          <input type="password" id="server-input-apikey" placeholder="Enter API Key" />
        </div>
        <div class="form-group checkbox-group">
          <input type="checkbox" id="server-input-active" checked />
          <label for="server-input-active">Set as active server</label>
        </div>
        <div id="server-modal-test-result" class="test-result-badge"></div>
      </div>
      <div class="modal-footer">
        <button type="button" id="server-btn-test" class="secondary-btn">🔌 Test Connection</button>
        <button id="server-modal-cancel" class="secondary-btn">Cancel</button>
        <button id="server-modal-save" class="primary-btn">Save Profile</button>
      </div>
    </div>
  </div>

  <!-- Session History Modal Dialog -->
  <div id="session-history-modal" class="modal-overlay hidden">
    <div class="modal-content">
      <div class="modal-header">
        <h3>🕒 Session History (.tealkit/sessions)</h3>
        <button id="session-history-close" class="close-btn">✕</button>
      </div>
      <div class="modal-body">
        <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 6px;">
          <span style="font-size: 11px; color: var(--vscode-descriptionForeground);">Auto-saved sessions can be resumed at any time.</span>
          <div style="display: flex; gap: 6px;">
            <button type="button" id="modal-new-session-btn" class="primary-btn-sm">+ New Session</button>
            <button type="button" id="modal-refresh-sessions-btn" class="icon-btn-sm" title="Refresh">🔄</button>
          </div>
        </div>
        <div id="session-history-list" class="cards-list" style="max-height: 340px; overflow-y: auto;">
          <div class="loading-state">Loading sessions...</div>
        </div>
      </div>
      <div class="modal-footer">
        <button id="session-history-close-btn" class="secondary-btn">Close</button>
      </div>
    </div>
  </div>

  <script src="${scriptUri}"></script>
</body>
</html>`;
  }
}
