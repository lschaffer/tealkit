import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';
import * as vscode from 'vscode';
import * as YAML from 'yaml';

export interface LlmProfileItem {
  name: string;
  provider: string;
  model: string;
  apiKey?: string;
  baseUrl?: string;
  isDefault?: boolean;
  temperature?: number;
  maxTokens?: number;
  topP?: number;
  topK?: number;
  repeatPenalty?: number;
  contextSize?: number;
  isSlm?: boolean;
  thinking?: boolean;
  useStreaming?: boolean;
  contextWindow?: string;
  pricing?: string;
  ctxAndPricing?: string;
}

export interface McpServerItem {
  name: string;
  command: string;
  args: string[];
  env: Record<string, string>;
  enabled: boolean;
}

export interface ServerProfileItem {
  name: string;
  url: string;
  apiKey: string;
  isActive: boolean;
}

export interface SkillItem {
  name: string;
  description: string;
  path: string;
  isAttached?: boolean;
}

export interface MemoryArchiveItem {
  archiveId: string;
  timestamp: string;
  turnCount: number;
  path: string;
}

export interface CliRagConfig {
  enabled: boolean;
  databasePath: string;
  folders: string[];
  web: string[];
  maxPages: number;
  fileExtensions: string[];
  chunkSize: number;
  chunkOverlap: number;
  embeddingProvider: string;
  embeddingModel: string;
  embeddingGpuLayers: number;
  embeddingBaseUrl: string;
  embeddingApiKey: string;
  searchMode: string;
  maxChunks: number;
  minScore: number;
}

export interface CliPermissionsConfig {
  autoApproveRead: boolean;
  autoApproveWrite: boolean;
  autoApproveExecute: boolean;
  autoApproveNetwork: boolean;
}

export interface CliGenericConfig {
  configPath: string;
  multiline: boolean;
  submitKey: string;
  autoPasteImages: boolean;
  planning: boolean;
  compressionThreshold: number;
  maxToolIterations: number;
  progressiveTools: string;
  compactTools: boolean;
  maxTurns: number;
  maxSizeMb: number;
  autoSave: boolean;
  permissions: CliPermissionsConfig;
  rag: CliRagConfig;
}

export class TealKitYamlConfigManager {
  /**
   * Resolves the primary llm.yaml file (workspace first, then ~/.tealkitcoder/llm.yaml).
   */
  public static getLlmConfigPath(): string {
    const workspaceFolders = vscode.workspace.workspaceFolders;
    if (workspaceFolders && workspaceFolders.length > 0) {
      const localPath = path.join(workspaceFolders[0].uri.fsPath, 'llm.yaml');
      if (fs.existsSync(localPath)) return localPath;
      const tealkitLocal = path.join(workspaceFolders[0].uri.fsPath, '.tealkit', 'llm.yaml');
      if (fs.existsSync(tealkitLocal)) return tealkitLocal;
    }
    const globalPath = path.join(os.homedir(), '.tealkitcoder', 'llm.yaml');
    if (!fs.existsSync(globalPath)) {
      const dir = path.dirname(globalPath);
      if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    }
    return globalPath;
  }

  /**
   * Resolves the primary mcp.yaml file (workspace first, then ~/.tealkitcoder/mcp.yaml).
   */
  public static getMcpConfigPath(): string {
    const workspaceFolders = vscode.workspace.workspaceFolders;
    if (workspaceFolders && workspaceFolders.length > 0) {
      const localPath = path.join(workspaceFolders[0].uri.fsPath, 'mcp.yaml');
      if (fs.existsSync(localPath)) return localPath;
      const tealkitLocal = path.join(workspaceFolders[0].uri.fsPath, '.tealkit', 'mcp.yaml');
      if (fs.existsSync(tealkitLocal)) return tealkitLocal;
      const externLocal = path.join(workspaceFolders[0].uri.fsPath, 'extern_mcp_tools.yaml');
      if (fs.existsSync(externLocal)) return externLocal;
    }
    const globalPath = path.join(os.homedir(), '.tealkitcoder', 'mcp.yaml');
    if (!fs.existsSync(globalPath)) {
      const dir = path.dirname(globalPath);
      if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    }
    return globalPath;
  }

  public static inferModelSpecs(model: string, provider: string): { ctxAndPricing?: string; contextWindow?: string; pricing?: string } {
    const m = (model || '').toLowerCase();
    const p = (provider || '').toLowerCase();

    if (p === 'ollama' || p === 'embedded' || (m.includes('qwen-coder') && m.includes('gguf'))) {
      return { ctxAndPricing: 'Free', pricing: 'Free' };
    }
    if (m.includes('gemma-4-31b') || m.includes('gemma-4')) {
      return { ctxAndPricing: '262k ctx \u2022 $0.20/$0.40', contextWindow: '262k ctx', pricing: '$0.20/$0.40' };
    }
    if (m.includes('qwen2.5-coder-32b') || m.includes('qwen3-coder') || m.includes('qwen2.5-72b')) {
      return { ctxAndPricing: '128k ctx \u2022 $0.15/$0.30', contextWindow: '128k ctx', pricing: '$0.15/$0.30' };
    }
    if (m.includes('deepseek-chat') || m.includes('deepseek-flash') || m.includes('deepseek-v4') || m.includes('deepseek-coder')) {
      return { ctxAndPricing: '64k ctx \u2022 $0.14/$0.28', contextWindow: '64k ctx', pricing: '$0.14/$0.28' };
    }
    if (m.includes('claude-3-5-sonnet') || m.includes('claude-3.5-sonnet')) {
      return { ctxAndPricing: '200k ctx \u2022 $3.00/$15.00', contextWindow: '200k ctx', pricing: '$3.00/$15.00' };
    }
    if (m.includes('gemini-3.7') || m.includes('gemini-2.0') || m.includes('gemini-1.5')) {
      return { ctxAndPricing: '1M ctx \u2022 $0.15/$0.60', contextWindow: '1M ctx', pricing: '$0.15/$0.60' };
    }
    if (m.includes('mistral-medium') || m.includes('mistral-large')) {
      return { ctxAndPricing: '128k ctx \u2022 $0.40/$1.20', contextWindow: '128k ctx', pricing: '$0.40/$1.20' };
    }
    if (m.includes('gpt-4o-mini')) {
      return { ctxAndPricing: '128k ctx \u2022 $0.15/$0.60', contextWindow: '128k ctx', pricing: '$0.15/$0.60' };
    }
    if (m.includes('gpt-4o')) {
      return { ctxAndPricing: '128k ctx \u2022 $2.50/$10.00', contextWindow: '128k ctx', pricing: '$2.50/$10.00' };
    }
    return {};
  }

  public static loadLlmConfig(): { filePath: string; defaultModel: string; profiles: LlmProfileItem[] } {
    const filePath = this.getLlmConfigPath();
    if (!fs.existsSync(filePath)) {
      return { filePath, defaultModel: '', profiles: [] };
    }

    try {
      const raw = fs.readFileSync(filePath, 'utf-8');
      const doc = YAML.parse(raw) || {};
      const defaultModel = doc.default || '';
      const rawLlms = doc.llms || [];

      const defaultTemp = doc.temperature ?? 0.2;
      const defaultMaxTokens = doc.max_tokens ?? 8192;

      const profiles: LlmProfileItem[] = rawLlms.map((item: any) => {
        const specs = TealKitYamlConfigManager.inferModelSpecs(item.model || '', item.provider || '');
        const ctxAndPricing = item.ctx_and_pricing || specs.ctxAndPricing;
        return {
          name: item.name || '',
          provider: item.provider || 'openai_compatible',
          model: item.model || '',
          apiKey: item.api_key || '',
          baseUrl: item.base_url || '',
          isDefault: item.name === defaultModel || item.default === true,
          temperature: item.temperature ?? defaultTemp,
          maxTokens: item.max_tokens ?? defaultMaxTokens,
          topP: item.top_p !== undefined ? Number(item.top_p) : undefined,
          topK: item.top_k !== undefined ? Number(item.top_k) : undefined,
          repeatPenalty: item.repeat_penalty !== undefined ? Number(item.repeat_penalty) : undefined,
          contextSize: item.context_size !== undefined ? Number(item.context_size) : undefined,
          isSlm: item.is_slm !== undefined ? !!item.is_slm : undefined,
          thinking: item.thinking !== undefined ? !!item.thinking : undefined,
          useStreaming: item.use_streaming !== undefined ? !!item.use_streaming : undefined,
          contextWindow: item.context_window || specs.contextWindow,
          pricing: item.pricing || specs.pricing,
          ctxAndPricing: ctxAndPricing,
        };
      });

      return { filePath, defaultModel, profiles };
    } catch (e) {
      return { filePath, defaultModel: '', profiles: [] };
    }
  }

  public static saveLlmProfile(profile: LlmProfileItem, setAsDefault: boolean = false, originalName?: string): void {
    const filePath = this.getLlmConfigPath();
    let doc: any = {};
    if (fs.existsSync(filePath)) {
      try {
        doc = YAML.parse(fs.readFileSync(filePath, 'utf-8')) || {};
      } catch (_) {
        doc = {};
      }
    }

    if (!doc.llms) doc.llms = [];

    const lookupName = originalName || profile.name;
    const existingIdx = doc.llms.findIndex((p: any) => p.name === lookupName || p.name === profile.name);
    const newEntry: any = {
      name: profile.name,
      provider: profile.provider,
      model: profile.model,
    };
    if (profile.apiKey) newEntry.api_key = profile.apiKey;
    if (profile.baseUrl) newEntry.base_url = profile.baseUrl;
    if (profile.temperature !== undefined) newEntry.temperature = profile.temperature;
    if (profile.maxTokens !== undefined) newEntry.max_tokens = profile.maxTokens;
    if (profile.topP !== undefined) newEntry.top_p = profile.topP;
    if (profile.topK !== undefined) newEntry.top_k = profile.topK;
    if (profile.repeatPenalty !== undefined) newEntry.repeat_penalty = profile.repeatPenalty;
    if (profile.contextSize !== undefined) newEntry.context_size = profile.contextSize;
    if (profile.isSlm !== undefined) newEntry.is_slm = profile.isSlm;
    if (profile.thinking !== undefined) newEntry.thinking = profile.thinking;
    if (profile.useStreaming !== undefined) newEntry.use_streaming = profile.useStreaming;

    if (existingIdx >= 0) {
      const merged = { ...doc.llms[existingIdx], ...newEntry };
      if (!profile.apiKey) delete merged.api_key;
      if (!profile.baseUrl) delete merged.base_url;
      if (profile.topP === undefined) delete merged.top_p;
      if (profile.topK === undefined) delete merged.top_k;
      if (profile.repeatPenalty === undefined) delete merged.repeat_penalty;
      if (profile.contextSize === undefined) delete merged.context_size;
      doc.llms[existingIdx] = merged;
    } else {
      doc.llms.push(newEntry);
    }

    if (setAsDefault || !doc.default || (originalName && doc.default === originalName)) {
      doc.default = profile.name;
    }

    fs.writeFileSync(filePath, YAML.stringify(doc), 'utf-8');
  }

  public static deleteLlmProfile(name: string): void {
    const filePath = this.getLlmConfigPath();
    if (!fs.existsSync(filePath)) return;

    try {
      const doc = YAML.parse(fs.readFileSync(filePath, 'utf-8')) || {};
      if (Array.isArray(doc.llms)) {
        doc.llms = doc.llms.filter((p: any) => p.name !== name);
        if (doc.default === name) {
          doc.default = doc.llms.length > 0 ? doc.llms[0].name : '';
        }
        fs.writeFileSync(filePath, YAML.stringify(doc), 'utf-8');
      }
    } catch (_) {}
  }

  public static setDefaultLlmProfile(name: string): void {
    const filePath = this.getLlmConfigPath();
    if (!fs.existsSync(filePath)) return;

    try {
      const doc = YAML.parse(fs.readFileSync(filePath, 'utf-8')) || {};
      doc.default = name;
      fs.writeFileSync(filePath, YAML.stringify(doc), 'utf-8');
    } catch (_) {}
  }

  public static loadMcpConfig(): { filePath: string; servers: McpServerItem[] } {
    const filePath = this.getMcpConfigPath();
    if (!fs.existsSync(filePath)) {
      return { filePath, servers: [] };
    }

    try {
      const raw = fs.readFileSync(filePath, 'utf-8');
      const doc = YAML.parse(raw) || {};
      const rawServers = doc.servers || doc.mcpServers || {};
      const servers: McpServerItem[] = [];

      if (Array.isArray(rawServers)) {
        rawServers.forEach((item: any, idx: number) => {
          if (!item) return;
          const sName = item.name || item.id || `server_${idx}`;
          const cmd = item.custom_launch_command || item.command || (item.local_package ? `${item.local_install_method || 'npx'} ${item.local_package}` : '');
          servers.push({
            name: sName,
            command: cmd,
            args: Array.isArray(item.args) ? item.args : [],
            env: typeof item.env === 'object' && item.env !== null ? item.env : {},
            enabled: item.enabled !== false,
          });
        });
      } else if (typeof rawServers === 'object') {
        for (const [key, val] of Object.entries(rawServers)) {
          const item = val as any;
          if (!item) continue;
          const sName = item.name || item.id || key;
          const cmd = item.command || item.custom_launch_command || '';
          servers.push({
            name: sName,
            command: cmd,
            args: Array.isArray(item.args) ? item.args : [],
            env: typeof item.env === 'object' && item.env !== null ? item.env : {},
            enabled: item.enabled !== false,
          });
        }
      }

      return { filePath, servers };
    } catch (e) {
      return { filePath, servers: [] };
    }
  }

  public static saveMcpServer(server: McpServerItem, originalName?: string): void {
    const filePath = this.getMcpConfigPath();
    let doc: any = {};
    if (fs.existsSync(filePath)) {
      try {
        doc = YAML.parse(fs.readFileSync(filePath, 'utf-8')) || {};
      } catch (_) {
        doc = {};
      }
    }

    const lookupName = originalName || server.name;
    const fullLaunchCmd = server.args && server.args.length > 0
      ? `${server.command} ${server.args.join(' ')}`.trim()
      : server.command;

    if (Array.isArray(doc.servers)) {
      const idx = doc.servers.findIndex(
        (s: any) => s && (s.name === lookupName || s.id === lookupName || s.name === server.name || s.id === server.name)
      );
      const entry: any = {
        id: idx >= 0 && doc.servers[idx]?.id && doc.servers[idx].id !== lookupName ? doc.servers[idx].id : server.name,
        name: server.name,
        is_local: true,
        custom_launch_command: fullLaunchCmd,
        command: server.command,
        args: server.args,
        env: server.env,
        enabled: server.enabled,
      };
      if (idx >= 0) {
        doc.servers[idx] = { ...doc.servers[idx], ...entry };
      } else {
        doc.servers.push(entry);
      }
    } else {
      if (!doc.mcpServers) doc.mcpServers = {};
      if (originalName && originalName !== server.name && doc.mcpServers[originalName]) {
        delete doc.mcpServers[originalName];
      }
      doc.mcpServers[server.name] = {
        command: server.command,
        args: server.args,
        env: server.env,
        enabled: server.enabled,
      };
    }

    fs.writeFileSync(filePath, YAML.stringify(doc), 'utf-8');
  }

  public static deleteMcpServer(name: string): void {
    const filePath = this.getMcpConfigPath();
    if (!fs.existsSync(filePath)) return;

    try {
      const doc = YAML.parse(fs.readFileSync(filePath, 'utf-8')) || {};
      if (Array.isArray(doc.servers)) {
        doc.servers = doc.servers.filter((s: any) => s && s.name !== name && s.id !== name);
        fs.writeFileSync(filePath, YAML.stringify(doc), 'utf-8');
      } else if (doc.mcpServers && doc.mcpServers[name]) {
        delete doc.mcpServers[name];
        fs.writeFileSync(filePath, YAML.stringify(doc), 'utf-8');
      }
    } catch (_) {}
  }

  public static toggleMcpServer(name: string, enabled: boolean): void {
    const filePath = this.getMcpConfigPath();
    if (!fs.existsSync(filePath)) return;

    try {
      const doc = YAML.parse(fs.readFileSync(filePath, 'utf-8')) || {};
      if (Array.isArray(doc.servers)) {
        const target = doc.servers.find((s: any) => s && (s.name === name || s.id === name));
        if (target) {
          target.enabled = enabled;
          fs.writeFileSync(filePath, YAML.stringify(doc), 'utf-8');
        }
      } else if (doc.mcpServers && doc.mcpServers[name]) {
        doc.mcpServers[name].enabled = enabled;
        fs.writeFileSync(filePath, YAML.stringify(doc), 'utf-8');
      }
    } catch (_) {}
  }

  // ─────────────────────────────────────────────────────────────
  // Server Configuration Management (server.yaml)
  // ─────────────────────────────────────────────────────────────
  public static getServerConfigPath(): string {
    const workspaceFolders = vscode.workspace.workspaceFolders;
    if (workspaceFolders && workspaceFolders.length > 0) {
      const localPath = path.join(workspaceFolders[0].uri.fsPath, 'server.yaml');
      if (fs.existsSync(localPath)) return localPath;
      const tealkitLocal = path.join(workspaceFolders[0].uri.fsPath, '.tealkit', 'server.yaml');
      if (fs.existsSync(tealkitLocal)) return tealkitLocal;
    }
    const globalPath = path.join(os.homedir(), '.tealkitcoder', 'server.yaml');
    if (!fs.existsSync(globalPath)) {
      const dir = path.dirname(globalPath);
      if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    }
    return globalPath;
  }

  public static loadServerConfig(): { filePath: string; profiles: ServerProfileItem[] } {
    const filePath = this.getServerConfigPath();
    if (!fs.existsSync(filePath)) {
      return { filePath, profiles: [] };
    }

    try {
      const raw = fs.readFileSync(filePath, 'utf-8');
      const doc = YAML.parse(raw) || {};
      const servers = doc.servers || [];

      const profiles: ServerProfileItem[] = servers.map((s: any) => ({
        name: s.name || 'Unnamed',
        url: s.url || 'http://localhost:7771',
        apiKey: s.api_key || '',
        isActive: s.is_active === true,
      }));

      return { filePath, profiles };
    } catch (e) {
      return { filePath, profiles: [] };
    }
  }

  public static saveServerProfile(profile: ServerProfileItem, originalName?: string): void {
    const filePath = this.getServerConfigPath();
    let doc: any = {};
    if (fs.existsSync(filePath)) {
      try {
        doc = YAML.parse(fs.readFileSync(filePath, 'utf-8')) || {};
      } catch (_) {
        doc = {};
      }
    }

    if (!doc.servers) doc.servers = [];

    if (profile.isActive) {
      for (const s of doc.servers) {
        s.is_active = false;
      }
    }

    const lookupName = originalName || profile.name;
    const idx = doc.servers.findIndex((s: any) => s.name === lookupName || s.name === profile.name);
    const entry: any = {
      name: profile.name,
      url: profile.url,
      api_key: profile.apiKey,
      is_active: profile.isActive,
    };

    if (idx >= 0) {
      doc.servers[idx] = entry;
    } else {
      doc.servers.push(entry);
    }

    fs.writeFileSync(filePath, YAML.stringify(doc), 'utf-8');
  }

  public static deleteServerProfile(name: string): void {
    const filePath = this.getServerConfigPath();
    if (!fs.existsSync(filePath)) return;

    try {
      const doc = YAML.parse(fs.readFileSync(filePath, 'utf-8')) || {};
      if (Array.isArray(doc.servers)) {
        doc.servers = doc.servers.filter((s: any) => s.name !== name);
        fs.writeFileSync(filePath, YAML.stringify(doc), 'utf-8');
      }
    } catch (_) {}
  }

  public static activateServerProfile(name: string): void {
    const filePath = this.getServerConfigPath();
    if (!fs.existsSync(filePath)) return;

    try {
      const doc = YAML.parse(fs.readFileSync(filePath, 'utf-8')) || {};
      if (Array.isArray(doc.servers)) {
        for (const s of doc.servers) {
          s.is_active = s.name === name;
        }
        fs.writeFileSync(filePath, YAML.stringify(doc), 'utf-8');
      }
    } catch (_) {}
  }

  // ─────────────────────────────────────────────────────────────
  // Skills Management (~/.tealkitcoder/skills & workspace skills/)
  // ─────────────────────────────────────────────────────────────
  public static getSkillsDirectory(): string {
    const globalSkills = path.join(os.homedir(), '.tealkitcoder', 'skills');
    if (!fs.existsSync(globalSkills)) {
      fs.mkdirSync(globalSkills, { recursive: true });
    }
    return globalSkills;
  }

  public static loadSkillsList(attachedSkills: string[] = []): { directory: string; skills: SkillItem[] } {
    const globalDir = this.getSkillsDirectory();
    const searchDirs = [globalDir];

    const workspaceFolders = vscode.workspace.workspaceFolders;
    if (workspaceFolders && workspaceFolders.length > 0) {
      const wsSkills = path.join(workspaceFolders[0].uri.fsPath, 'skills');
      if (fs.existsSync(wsSkills)) searchDirs.push(wsSkills);
      const wsTkSkills = path.join(workspaceFolders[0].uri.fsPath, '.tealkit', 'skills');
      if (fs.existsSync(wsTkSkills)) searchDirs.push(wsTkSkills);
    }

    const skills: SkillItem[] = [];
    const seenNames = new Set<string>();

    for (const dir of searchDirs) {
      if (!fs.existsSync(dir)) continue;
      const files = fs.readdirSync(dir);
      for (const file of files) {
        if (!file.endsWith('.md')) continue;
        const filePath = path.join(dir, file);
        try {
          const content = fs.readFileSync(filePath, 'utf-8');
          const skill = this.parseSkillFrontmatter(content, filePath);
          if (!seenNames.has(skill.name)) {
            seenNames.add(skill.name);
            skill.isAttached = attachedSkills.includes(skill.name);
            skills.push(skill);
          }
        } catch (_) {}
      }
    }

    return { directory: globalDir, skills };
  }

  private static parseSkillFrontmatter(content: string, filePath: string): SkillItem {
    let name = path.basename(filePath, '.md');
    let description = '';

    const normalized = content.replace(/^\uFEFF/, '');
    const fmMatch = normalized.match(/^---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)/);
    if (fmMatch) {
      const yamlStr = fmMatch[1];
      try {
        const doc = YAML.parse(yamlStr) || {};
        if (doc.name) name = String(doc.name).trim();
        if (doc.description) description = String(doc.description).trim();
      } catch (_) {}
      if (!description) {
        const descLine = yamlStr.match(/^description:\s*["']?(.+?)["']?\s*$/m);
        if (descLine && descLine[1]) description = descLine[1].trim();
      }
    }
    if (false && content.startsWith('---')) {
      const endIdx = content.indexOf('---', 3);
      if (endIdx > 0) {
        const yamlStr = content.substring(3, endIdx);
        try {
          const doc = YAML.parse(yamlStr) || {};
          if (doc.name) name = doc.name;
          if (doc.description) description = doc.description;
        } catch (_) {}
      }
    }

    return { name, description, path: filePath };
  }

  public static saveSkillFile(name: string, content: string): string {
    const dir = this.getSkillsDirectory();
    const fileName = name.endsWith('.md') ? name : `${name}.md`;
    const filePath = path.join(dir, fileName);
    fs.writeFileSync(filePath, content, 'utf-8');
    return filePath;
  }

  // ─────────────────────────────────────────────────────────────
  // Memory Archive Management (.tealkit/memory)
  // ─────────────────────────────────────────────────────────────
  public static loadMemoryArchives(): MemoryArchiveItem[] {
    const searchDirs: string[] = [];

    const workspaceFolders = vscode.workspace.workspaceFolders;
    if (workspaceFolders && workspaceFolders.length > 0) {
      searchDirs.push(path.join(workspaceFolders[0].uri.fsPath, '.tealkit', 'memory'));
    }
    searchDirs.push(path.join(os.homedir(), '.tealkitcoder', 'memory'));

    const archives: MemoryArchiveItem[] = [];

    for (const dir of searchDirs) {
      if (!fs.existsSync(dir)) continue;
      const files = fs.readdirSync(dir);
      for (const file of files) {
        if (!file.endsWith('.json')) continue;
        const filePath = path.join(dir, file);
        try {
          const raw = fs.readFileSync(filePath, 'utf-8');
          const data = JSON.parse(raw);
          archives.push({
            archiveId: data.archiveId || path.basename(file, '.json'),
            timestamp: data.timestamp || new Date().toISOString(),
            turnCount: data.turnCount || (data.turns ? data.turns.length : 0),
            path: filePath,
          });
        } catch (_) {}
      }
    }

    archives.sort((a, b) => b.timestamp.localeCompare(a.timestamp));
    return archives;
  }

  // ─────────────────────────────────────────────────────────────
  // Generic CLI Settings (config.yaml)
  // ─────────────────────────────────────────────────────────────
  public static getCliConfigPath(): string {
    const workspaceFolders = vscode.workspace.workspaceFolders;
    if (workspaceFolders && workspaceFolders.length > 0) {
      const localPath = path.join(workspaceFolders[0].uri.fsPath, 'config.yaml');
      if (fs.existsSync(localPath)) return localPath;
      const tealkitLocal = path.join(workspaceFolders[0].uri.fsPath, '.tealkit', 'config.yaml');
      if (fs.existsSync(tealkitLocal)) return tealkitLocal;
    }
    const globalPath = path.join(os.homedir(), '.tealkitcoder', 'config.yaml');
    if (!fs.existsSync(globalPath)) {
      const dir = path.dirname(globalPath);
      if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    }
    return globalPath;
  }

  public static getPermissionsConfigPath(): string {
    return path.join(os.homedir(), '.tealkitcoder', 'permissions.yaml');
  }

  public static loadCliConfig(): CliGenericConfig {
    const configPath = this.getCliConfigPath();
    let multiline = false;
    let submitKey = 'enter';
    let autoPasteImages = true;
    let planning = true;
    let compressionThreshold = 4000;
    let maxToolIterations = 100;
    let progressiveTools = 'auto';
    let compactTools = true;
    let maxTurns = 500;
    let maxSizeMb = 10;
    let autoSave = true;

    const permissions: CliPermissionsConfig = {
      autoApproveRead: true,
      autoApproveWrite: false,
      autoApproveExecute: false,
      autoApproveNetwork: false,
    };

    const rag: CliRagConfig = {
      enabled: true,
      databasePath: 'rag_index.db',
      folders: [],
      web: [],
      maxPages: 50,
      fileExtensions: ['.txt', '.md', '.pdf', '.docx', '.csv', '.json'],
      chunkSize: 1000,
      chunkOverlap: 150,
      embeddingProvider: 'embedded',
      embeddingModel: 'nomic-embed-text-v1.5.Q4_K_M.gguf',
      embeddingGpuLayers: 0,
      embeddingBaseUrl: 'http://localhost:11434',
      embeddingApiKey: '',
      searchMode: 'hybrid',
      maxChunks: 5,
      minScore: 0.15,
    };

    // Load permissions.yaml fallback first
    const permPath = this.getPermissionsConfigPath();
    if (fs.existsSync(permPath)) {
      try {
        const permDoc = YAML.parse(fs.readFileSync(permPath, 'utf-8')) || {};
        if (typeof permDoc.auto_approve_read === 'boolean') permissions.autoApproveRead = permDoc.auto_approve_read;
        if (typeof permDoc.auto_approve_write === 'boolean') permissions.autoApproveWrite = permDoc.auto_approve_write;
        if (typeof permDoc.auto_approve_execute === 'boolean') permissions.autoApproveExecute = permDoc.auto_approve_execute;
        if (typeof permDoc.auto_approve_network === 'boolean') permissions.autoApproveNetwork = permDoc.auto_approve_network;
      } catch (_) {}
    }

    if (fs.existsSync(configPath)) {
      try {
        const raw = fs.readFileSync(configPath, 'utf-8');
        const doc = YAML.parse(raw) || {};
        let needsSyncWrite = false;

        if (doc.prompt) {
          if (typeof doc.prompt.multiline === 'boolean') multiline = doc.prompt.multiline;
          if (typeof doc.prompt.submit_key === 'string') submitKey = doc.prompt.submit_key;
          if (typeof doc.prompt.auto_paste_images === 'boolean') autoPasteImages = doc.prompt.auto_paste_images;
        }
        if (doc.agent) {
          if (typeof doc.agent.planning === 'boolean') planning = doc.agent.planning;
          if (typeof doc.agent.compression_threshold === 'number') compressionThreshold = doc.agent.compression_threshold;
          if (typeof doc.agent.max_tool_iterations === 'number') {
            maxToolIterations = doc.agent.max_tool_iterations;
          } else {
            doc.agent.max_tool_iterations = maxToolIterations;
            needsSyncWrite = true;
          }
          if (typeof doc.agent.progressive_tools === 'string') progressiveTools = doc.agent.progressive_tools;
        }
        if (typeof doc.compact_tools === 'boolean') compactTools = doc.compact_tools;
        if (doc.session) {
          if (typeof doc.session.max_turns === 'number') maxTurns = doc.session.max_turns;
          if (typeof doc.session.max_size_mb === 'number') maxSizeMb = doc.session.max_size_mb;
          if (typeof doc.session.auto_save === 'boolean') autoSave = doc.session.auto_save;
        }
        if (doc.permissions && typeof doc.permissions === 'object') {
          if (typeof doc.permissions.auto_approve_read === 'boolean') permissions.autoApproveRead = doc.permissions.auto_approve_read;
          if (typeof doc.permissions.auto_approve_write === 'boolean') permissions.autoApproveWrite = doc.permissions.auto_approve_write;
          if (typeof doc.permissions.auto_approve_execute === 'boolean') permissions.autoApproveExecute = doc.permissions.auto_approve_execute;
          if (typeof doc.permissions.auto_approve_network === 'boolean') permissions.autoApproveNetwork = doc.permissions.auto_approve_network;
        } else {
          doc.permissions = {
            auto_approve_read: permissions.autoApproveRead,
            auto_approve_write: permissions.autoApproveWrite,
            auto_approve_execute: permissions.autoApproveExecute,
            auto_approve_network: permissions.autoApproveNetwork,
          };
          needsSyncWrite = true;
        }
        if (doc.rag && typeof doc.rag === 'object') {
          const r = doc.rag;
          if (typeof r.enabled === 'boolean') rag.enabled = r.enabled;
          if (typeof r.database_path === 'string') rag.databasePath = r.database_path;
          if (r.sources && typeof r.sources === 'object') {
            if (Array.isArray(r.sources.folders)) rag.folders = r.sources.folders.map((x: any) => String(x)).filter(Boolean);
            if (Array.isArray(r.sources.web)) rag.web = r.sources.web.map((x: any) => String(x)).filter(Boolean);
            if (typeof r.sources.max_pages === 'number') rag.maxPages = r.sources.max_pages;
          }
          if (Array.isArray(r.file_extensions)) {
            rag.fileExtensions = r.file_extensions.map((x: any) => String(x)).filter(Boolean);
          }
          if (r.chunking && typeof r.chunking === 'object') {
            if (typeof r.chunking.chunk_size === 'number') rag.chunkSize = r.chunking.chunk_size;
            if (typeof r.chunking.chunk_overlap === 'number') rag.chunkOverlap = r.chunking.chunk_overlap;
          }
          if (r.embedding && typeof r.embedding === 'object') {
            if (typeof r.embedding.provider === 'string') rag.embeddingProvider = r.embedding.provider;
            if (typeof r.embedding.model === 'string') rag.embeddingModel = r.embedding.model;
            if (typeof r.embedding.gpu_layers === 'number') rag.embeddingGpuLayers = r.embedding.gpu_layers;
            if (typeof r.embedding.base_url === 'string') rag.embeddingBaseUrl = r.embedding.base_url;
            if (typeof r.embedding.api_key === 'string') rag.embeddingApiKey = r.embedding.api_key;
          }
          if (r.search && typeof r.search === 'object') {
            if (typeof r.search.mode === 'string') rag.searchMode = r.search.mode;
            if (typeof r.search.max_chunks === 'number') rag.maxChunks = r.search.max_chunks;
            if (typeof r.search.min_score === 'number') rag.minScore = r.search.min_score;
          }
        }

        if (needsSyncWrite) {
          try {
            fs.writeFileSync(configPath, YAML.stringify(doc), 'utf-8');
          } catch (_) {}
        }
      } catch (e) {
        console.error('Failed to parse config.yaml:', e);
      }
    }

    return {
      configPath,
      multiline,
      submitKey,
      autoPasteImages,
      planning,
      compressionThreshold,
      maxToolIterations,
      progressiveTools,
      compactTools,
      maxTurns,
      maxSizeMb,
      autoSave,
      permissions,
      rag,
    };
  }

  public static saveCliConfig(cfg: Partial<CliGenericConfig>): void {
    const configPath = this.getCliConfigPath();
    let doc: any = {};
    if (fs.existsSync(configPath)) {
      try {
        const raw = fs.readFileSync(configPath, 'utf-8');
        doc = YAML.parse(raw) || {};
      } catch (_) {}
    }

    if (!doc.prompt || typeof doc.prompt !== 'object') doc.prompt = {};
    if (!doc.agent || typeof doc.agent !== 'object') doc.agent = {};
    if (!doc.session || typeof doc.session !== 'object') doc.session = {};
    if (!doc.permissions || typeof doc.permissions !== 'object') doc.permissions = {};
    if (!doc.rag || typeof doc.rag !== 'object') doc.rag = {};

    if (typeof cfg.multiline === 'boolean') doc.prompt.multiline = cfg.multiline;
    if (typeof cfg.submitKey === 'string') doc.prompt.submit_key = cfg.submitKey;
    if (typeof cfg.autoPasteImages === 'boolean') doc.prompt.auto_paste_images = cfg.autoPasteImages;

    if (typeof cfg.planning === 'boolean') doc.agent.planning = cfg.planning;
    if (typeof cfg.compressionThreshold === 'number') doc.agent.compression_threshold = cfg.compressionThreshold;
    if (typeof cfg.maxToolIterations === 'number') doc.agent.max_tool_iterations = cfg.maxToolIterations;
    if (typeof cfg.progressiveTools === 'string') doc.agent.progressive_tools = cfg.progressiveTools;

    if (typeof cfg.compactTools === 'boolean') doc.compact_tools = cfg.compactTools;

    if (typeof cfg.maxSizeMb === 'number') doc.session.max_size_mb = cfg.maxSizeMb;
    if (typeof cfg.maxTurns === 'number') doc.session.max_turns = cfg.maxTurns;
    if (typeof cfg.autoSave === 'boolean') doc.session.auto_save = cfg.autoSave;
    if (!doc.session.file_pattern) doc.session.file_pattern = 'tealkitcoder_session_{timestamp}.json';

    if (cfg.permissions) {
      if (typeof cfg.permissions.autoApproveRead === 'boolean') doc.permissions.auto_approve_read = cfg.permissions.autoApproveRead;
      if (typeof cfg.permissions.autoApproveWrite === 'boolean') doc.permissions.auto_approve_write = cfg.permissions.autoApproveWrite;
      if (typeof cfg.permissions.autoApproveExecute === 'boolean') doc.permissions.auto_approve_execute = cfg.permissions.autoApproveExecute;
      if (typeof cfg.permissions.autoApproveNetwork === 'boolean') doc.permissions.auto_approve_network = cfg.permissions.autoApproveNetwork;

      try {
        const permPath = this.getPermissionsConfigPath();
        const permDir = path.dirname(permPath);
        if (!fs.existsSync(permDir)) fs.mkdirSync(permDir, { recursive: true });
        fs.writeFileSync(
          permPath,
          YAML.stringify({
            auto_approve_read: doc.permissions.auto_approve_read ?? true,
            auto_approve_write: doc.permissions.auto_approve_write ?? false,
            auto_approve_execute: doc.permissions.auto_approve_execute ?? false,
            auto_approve_network: doc.permissions.auto_approve_network ?? false,
          }),
          'utf-8'
        );
      } catch (_) {}
    }

    if (cfg.rag) {
      const r = cfg.rag;
      if (typeof r.enabled === 'boolean') doc.rag.enabled = r.enabled;
      if (typeof r.databasePath === 'string') doc.rag.database_path = r.databasePath;
      if (!doc.rag.sources || typeof doc.rag.sources !== 'object') doc.rag.sources = {};
      if (Array.isArray(r.folders)) doc.rag.sources.folders = r.folders;
      if (Array.isArray(r.web)) doc.rag.sources.web = r.web;
      if (typeof r.maxPages === 'number') doc.rag.sources.max_pages = r.maxPages;
      if (Array.isArray(r.fileExtensions)) doc.rag.file_extensions = r.fileExtensions;
      if (!doc.rag.chunking || typeof doc.rag.chunking !== 'object') doc.rag.chunking = {};
      if (typeof r.chunkSize === 'number') doc.rag.chunking.chunk_size = r.chunkSize;
      if (typeof r.chunkOverlap === 'number') doc.rag.chunking.chunk_overlap = r.chunkOverlap;
      if (!doc.rag.embedding || typeof doc.rag.embedding !== 'object') doc.rag.embedding = {};
      if (typeof r.embeddingProvider === 'string') doc.rag.embedding.provider = r.embeddingProvider;
      if (typeof r.embeddingModel === 'string') doc.rag.embedding.model = r.embeddingModel;
      if (typeof r.embeddingGpuLayers === 'number') doc.rag.embedding.gpu_layers = r.embeddingGpuLayers;
      if (typeof r.embeddingBaseUrl === 'string') doc.rag.embedding.base_url = r.embeddingBaseUrl;
      if (typeof r.embeddingApiKey === 'string') doc.rag.embedding.api_key = r.embeddingApiKey;
      if (!doc.rag.search || typeof doc.rag.search !== 'object') doc.rag.search = {};
      if (typeof r.searchMode === 'string') doc.rag.search.mode = r.searchMode;
      if (typeof r.maxChunks === 'number') doc.rag.search.max_chunks = r.maxChunks;
      if (typeof r.minScore === 'number') doc.rag.search.min_score = r.minScore;
    }

    const dir = path.dirname(configPath);
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(configPath, YAML.stringify(doc), 'utf-8');
  }
}
