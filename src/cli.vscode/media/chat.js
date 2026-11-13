(function () {
  const vscode = acquireVsCodeApi();

  // Panels and Navigation Tabs
  const tabBtnChat = document.getElementById('tab-btn-chat');
  const tabBtnLlms = document.getElementById('tab-btn-llms');
  const tabBtnMcp = document.getElementById('tab-btn-mcp');
  const tabBtnSkills = document.getElementById('tab-btn-skills');
  const tabBtnMemory = document.getElementById('tab-btn-memory');
  const tabBtnServer = document.getElementById('tab-btn-server');

  const panelChat = document.getElementById('panel-chat');
  const panelLlms = document.getElementById('panel-llms');
  const panelMcp = document.getElementById('panel-mcp');
  const panelSkills = document.getElementById('panel-skills');
  const panelMemory = document.getElementById('panel-memory');
  const panelServer = document.getElementById('panel-server');

  // Chat Elements
  const messagesContainer = document.getElementById('messages');
  const promptInput = document.getElementById('prompt-input');
  const sendBtn = document.getElementById('send-btn');
  const clearBtn = document.getElementById('clear-btn');
  const tasksBtn = document.getElementById('tasks-btn');
  const gearBtn = document.getElementById('gear-btn');
  const cancelBtn = document.getElementById('cancel-btn');
  const modeSelect = document.getElementById('mode-select');
  const modelSelect = document.getElementById('model-select');
  const statusBadge = document.getElementById('agent-status-badge');
  const toolsBadge = document.getElementById('tools-badge');
  const activityBar = document.getElementById('activity-indicator');
  const activityText = document.getElementById('activity-text');
  const attachedSkillsChips = document.getElementById('attached-skills-chips');
  const quickAttachBtn = document.getElementById('quick-attach-btn');

  // LLM Panel Elements
  const llmFilePathEl = document.getElementById('llm-file-path');
  const openLlmFileBtn = document.getElementById('open-llm-file-btn');
  const addLlmBtn = document.getElementById('add-llm-btn');
  const refreshLlmBtn = document.getElementById('refresh-llm-btn');
  const llmListEl = document.getElementById('llm-list');
  const llmModal = document.getElementById('llm-modal');
  const llmModalTitle = document.getElementById('llm-modal-title');
  const llmModalClose = document.getElementById('llm-modal-close');
  const llmModalCancel = document.getElementById('llm-modal-cancel');
  const llmModalSave = document.getElementById('llm-modal-save');
  const llmInputName = document.getElementById('llm-input-name');
  const llmInputProvider = document.getElementById('llm-input-provider');
  const llmInputModel = document.getElementById('llm-input-model');
  const llmInputBaseUrl = document.getElementById('llm-input-baseurl');
  const llmInputApiKey = document.getElementById('llm-input-apikey');
  const llmInputDefault = document.getElementById('llm-input-default');
  const llmInputTemp = document.getElementById('llm-input-temp');
  const llmInputMaxTokens = document.getElementById('llm-input-maxtokens');
  const llmInputContextSize = document.getElementById('llm-input-context-size');
  const llmInputTopP = document.getElementById('llm-input-topp');
  const llmInputTopK = document.getElementById('llm-input-topk');
  const llmInputRepeatPenalty = document.getElementById('llm-input-repeat-penalty');
  const llmInputIsSlm = document.getElementById('llm-input-isslm');
  const llmInputThinking = document.getElementById('llm-input-thinking');
  const llmInputStreaming = document.getElementById('llm-input-streaming');
  const toggleApiKeyVisibility = document.getElementById('toggle-apikey-visibility');
  const llmBtnLoadModels = document.getElementById('llm-btn-load-models');
  const llmModelDatalist = document.getElementById('llm-model-datalist');
  const llmModelsStatus = document.getElementById('llm-models-status');
  const llmBtnTestApi = document.getElementById('llm-btn-test-api');
  const llmTestResult = document.getElementById('llm-test-result');

  function clearLlmFeedback() {
    if (llmModelsStatus) {
      llmModelsStatus.textContent = '';
      llmModelsStatus.className = 'hint-status';
    }
    if (llmTestResult) {
      llmTestResult.textContent = '';
      llmTestResult.className = 'test-result-badge';
    }
  }

  // MCP Panel Elements
  const mcpFilePathEl = document.getElementById('mcp-file-path');
  const openMcpFileBtn = document.getElementById('open-mcp-file-btn');
  const addMcpBtn = document.getElementById('add-mcp-btn');
  const refreshMcpBtn = document.getElementById('refresh-mcp-btn');
  const mcpListEl = document.getElementById('mcp-list');
  const mcpModal = document.getElementById('mcp-modal');
  const mcpModalTitle = document.getElementById('mcp-modal-title');
  const mcpModalClose = document.getElementById('mcp-modal-close');
  const mcpModalCancel = document.getElementById('mcp-modal-cancel');
  const mcpModalSave = document.getElementById('mcp-modal-save');
  const mcpInputName = document.getElementById('mcp-input-name');
  const mcpInputCommand = document.getElementById('mcp-input-command');
  const mcpInputArgs = document.getElementById('mcp-input-args');
  const mcpInputEnv = document.getElementById('mcp-input-env');
  const mcpInputEnabled = document.getElementById('mcp-input-enabled');
  const mcpBtnTest = document.getElementById('mcp-btn-test');
  const mcpModalToolsResult = document.getElementById('mcp-modal-tools-result');

  // Skills Panel Elements
  const skillsDirPathEl = document.getElementById('skills-dir-path');
  const openSkillsFolderBtn = document.getElementById('open-skills-folder-btn');
  const addSkillBtn = document.getElementById('add-skill-btn');
  const refreshSkillsBtn = document.getElementById('refresh-skills-btn');
  const skillsListEl = document.getElementById('skills-list');
  const skillModal = document.getElementById('skill-modal');
  const skillModalClose = document.getElementById('skill-modal-close');
  const skillModalCancel = document.getElementById('skill-modal-cancel');
  const skillModalSave = document.getElementById('skill-modal-save');
  const skillInputName = document.getElementById('skill-input-name');
  const skillInputDesc = document.getElementById('skill-input-desc');
  const skillInputPrompt = document.getElementById('skill-input-prompt');

  // Memory Archive & Session History Elements
  const historyBtn = document.getElementById('history-btn');
  const newSessionBtn = document.getElementById('new-session-btn');
  const memoryNewSessionBtn = document.getElementById('memory-new-session-btn');
  const refreshSessionsBtn = document.getElementById('refresh-sessions-btn');
  const savedSessionsListEl = document.getElementById('saved-sessions-list');
  const sessionHistoryModal = document.getElementById('session-history-modal');
  const sessionHistoryClose = document.getElementById('session-history-close');
  const sessionHistoryCloseBtn = document.getElementById('session-history-close-btn');
  const modalNewSessionBtn = document.getElementById('modal-new-session-btn');
  const modalRefreshSessionsBtn = document.getElementById('modal-refresh-sessions-btn');
  const sessionHistoryListEl = document.getElementById('session-history-list');
  let explicitSessionLoadRequested = false;

  const archiveNowBtn = document.getElementById('archive-now-btn');
  const refreshMemoryBtn = document.getElementById('refresh-memory-btn');
  const memoryListEl = document.getElementById('memory-list');

  // Server Panel Elements
  const serverConfigPathEl = document.getElementById('server-config-path');
  const openServerFileBtn = document.getElementById('open-server-file-btn');
  const addServerBtn = document.getElementById('add-server-btn');
  const refreshServerBtn = document.getElementById('refresh-server-btn');
  const refreshWorkflowsBtn = document.getElementById('refresh-workflows-btn');
  const serverProfilesListEl = document.getElementById('server-profiles-list');
  const workflowsListEl = document.getElementById('workflows-list');
  const serverModal = document.getElementById('server-modal');
  const serverModalTitle = document.getElementById('server-modal-title');
  const serverModalClose = document.getElementById('server-modal-close');
  const serverModalCancel = document.getElementById('server-modal-cancel');
  const serverModalSave = document.getElementById('server-modal-save');
  const serverInputName = document.getElementById('server-input-name');
  const serverInputUrl = document.getElementById('server-input-url');
  const serverInputApiKey = document.getElementById('server-input-apikey');
  const serverInputActive = document.getElementById('server-input-active');
  const serverBtnTest = document.getElementById('server-btn-test');
  const serverModalTestResult = document.getElementById('server-modal-test-result');

  // Settings Panel Elements
  const tabBtnSettings = document.getElementById('tab-btn-settings');
  const panelSettings = document.getElementById('panel-settings');
  const cliConfigPathEl = document.getElementById('cli-config-path');
  const reloadConfigBtn = document.getElementById('reload-config-btn');
  const openConfigFileBtn = document.getElementById('open-config-file-btn');
  const btnSaveCliSettings = document.getElementById('btn-save-cli-settings');
  const cfgSaveStatus = document.getElementById('cfg-save-status');

  const cfgMaxTurns = document.getElementById('cfg-max-turns');
  const cfgMaxSizeMb = document.getElementById('cfg-max-size-mb');
  const cfgMaxToolIterations = document.getElementById('cfg-max-tool-iterations');
  const cfgProgressiveTools = document.getElementById('cfg-progressive-tools');
  const cfgAutoSave = document.getElementById('cfg-auto-save');

  const cfgCompressionThreshold = document.getElementById('cfg-compression-threshold');
  const cfgSubmitKey = document.getElementById('cfg-submit-key');
  const cfgPlanning = document.getElementById('cfg-planning');
  const cfgCompactTools = document.getElementById('cfg-compact-tools');
  const cfgMultiline = document.getElementById('cfg-multiline');
  const cfgAutoPasteImages = document.getElementById('cfg-auto-paste-images');

  const cfgPermRead = document.getElementById('cfg-perm-read');
  const cfgPermWrite = document.getElementById('cfg-perm-write');
  const cfgPermExecute = document.getElementById('cfg-perm-execute');
  const cfgPermNetwork = document.getElementById('cfg-perm-network');

  const cfgRagEnabled = document.getElementById('cfg-rag-enabled');
  const cfgRagDbPath = document.getElementById('cfg-rag-db-path');
  const cfgRagFolders = document.getElementById('cfg-rag-folders');
  const cfgRagWeb = document.getElementById('cfg-rag-web');
  const cfgRagMaxPages = document.getElementById('cfg-rag-max-pages');
  const cfgRagExtensions = document.getElementById('cfg-rag-extensions');
  const cfgRagChunkSize = document.getElementById('cfg-rag-chunk-size');
  const cfgRagChunkOverlap = document.getElementById('cfg-rag-chunk-overlap');
  const cfgRagEmbedProvider = document.getElementById('cfg-rag-embed-provider');
  const cfgRagEmbedModel = document.getElementById('cfg-rag-embed-model');
  const cfgRagEmbedBaseurl = document.getElementById('cfg-rag-embed-baseurl');
  const cfgRagEmbedGpulayers = document.getElementById('cfg-rag-embed-gpulayers');
  const cfgRagEmbedApikey = document.getElementById('cfg-rag-embed-apikey');
  const cfgRagSearchMode = document.getElementById('cfg-rag-search-mode');
  const cfgRagMaxChunks = document.getElementById('cfg-rag-max-chunks');
  const cfgRagMinScore = document.getElementById('cfg-rag-min-score');

  let editingLlmOriginalName = null;
  let editingMcpOriginalName = null;
  let editingServerOriginalName = null;
  const workflowStateMap = {};


  let currentAssistantBubble = null;
  let isGenerating = false;
  let diffCounter = 0;
  let activeLlmFilePath = '';
  let activeMcpFilePath = '';
  let activeSkillsDirPath = '';
  let activeServerFilePath = '';
  let currentActiveSkills = [];
  let activeSelectedProfile = '';
  function updateRagModeOption(isRagConfigured) {
    if (!modeSelect) return;
    const ragOpt = modeSelect.querySelector('option[value="rag"]');
    if (!ragOpt) return;
    ragOpt.disabled = !isRagConfigured;
    ragOpt.textContent = isRagConfigured ? '📚 RAG' : '📚 RAG (Not Configured)';
    if (!isRagConfigured && modeSelect.value === 'rag') {
      modeSelect.value = 'code';
    }
  }

  // Signal ready to request models and status
  vscode.postMessage({ type: 'ready_request' });

  // Tab Switching Function
  window.switchTab = function (tabName) {
    const tabs = [tabBtnChat, tabBtnLlms, tabBtnMcp, tabBtnSkills, tabBtnMemory, tabBtnServer, tabBtnSettings];
    const panels = [panelChat, panelLlms, panelMcp, panelSkills, panelMemory, panelServer, panelSettings];

    tabs.forEach((b) => b && b.classList.remove('active'));
    panels.forEach((p) => p && p.classList.add('hidden'));

    if (tabName === 'chat' && tabBtnChat && panelChat) {
      tabBtnChat.classList.add('active');
      panelChat.classList.remove('hidden');
    } else if (tabName === 'llms' && tabBtnLlms && panelLlms) {
      tabBtnLlms.classList.add('active');
      panelLlms.classList.remove('hidden');
      vscode.postMessage({ type: 'get_llm_config' });
    } else if (tabName === 'mcp' && tabBtnMcp && panelMcp) {
      tabBtnMcp.classList.add('active');
      panelMcp.classList.remove('hidden');
      vscode.postMessage({ type: 'get_mcp_config' });
    } else if (tabName === 'skills' && tabBtnSkills && panelSkills) {
      tabBtnSkills.classList.add('active');
      panelSkills.classList.remove('hidden');
      vscode.postMessage({ type: 'get_skills' });
    } else if (tabName === 'memory' && tabBtnMemory && panelMemory) {
      tabBtnMemory.classList.add('active');
      panelMemory.classList.remove('hidden');
      vscode.postMessage({ type: 'list_sessions' });
      vscode.postMessage({ type: 'get_memory_archives' });
    } else if (tabName === 'server' && tabBtnServer && panelServer) {
      tabBtnServer.classList.add('active');
      panelServer.classList.remove('hidden');
      vscode.postMessage({ type: 'get_server_config' });
    } else if (tabName === 'settings' && tabBtnSettings && panelSettings) {
      tabBtnSettings.classList.add('active');
      panelSettings.classList.remove('hidden');
      vscode.postMessage({ type: 'get_cli_config' });
    }
  };

  if (tabBtnChat) tabBtnChat.addEventListener('click', () => window.switchTab('chat'));
  if (tabBtnLlms) tabBtnLlms.addEventListener('click', () => window.switchTab('llms'));
  if (tabBtnMcp) tabBtnMcp.addEventListener('click', () => window.switchTab('mcp'));
  if (tabBtnSkills) tabBtnSkills.addEventListener('click', () => window.switchTab('skills'));
  if (tabBtnMemory) tabBtnMemory.addEventListener('click', () => window.switchTab('memory'));
  if (tabBtnServer) tabBtnServer.addEventListener('click', () => window.switchTab('server'));

  if (tabBtnSettings) tabBtnSettings.addEventListener('click', () => window.switchTab('settings'));

  if (openConfigFileBtn) {
    openConfigFileBtn.addEventListener('click', () => {
      vscode.postMessage({ type: 'open_config_file' });
    });
  }

  if (reloadConfigBtn) {
    reloadConfigBtn.addEventListener('click', () => {
      if (cfgSaveStatus) {
        cfgSaveStatus.textContent = '🔄 Reloading config.yaml...';
        cfgSaveStatus.className = 'hint-status loading';
      }
      vscode.postMessage({ type: 'get_cli_config' });
    });
  }

  function collectCliSettingsFromForm() {
    const folders = (cfgRagFolders?.value || '')
      .split(/\r?\n/)
      .map((s) => s.trim())
      .filter(Boolean);
    const web = (cfgRagWeb?.value || '')
      .split(/\r?\n/)
      .map((s) => s.trim())
      .filter(Boolean);
    const fileExtensions = (cfgRagExtensions?.value || '.txt, .md, .pdf, .docx, .csv, .json')
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean);

    return {
      multiline: !!cfgMultiline?.checked,
      submitKey: cfgSubmitKey?.value || 'enter',
      autoPasteImages: !!cfgAutoPasteImages?.checked,
      planning: !!cfgPlanning?.checked,
      compressionThreshold: parseInt(cfgCompressionThreshold?.value || '4000', 10),
      maxToolIterations: parseInt(cfgMaxToolIterations?.value || '100', 10),
      progressiveTools: cfgProgressiveTools?.value || 'auto',
      compactTools: !!cfgCompactTools?.checked,
      maxTurns: parseInt(cfgMaxTurns?.value || '500', 10),
      maxSizeMb: parseInt(cfgMaxSizeMb?.value || '10', 10),
      autoSave: !!cfgAutoSave?.checked,
      permissions: {
        autoApproveRead: !!cfgPermRead?.checked,
        autoApproveWrite: !!cfgPermWrite?.checked,
        autoApproveExecute: !!cfgPermExecute?.checked,
        autoApproveNetwork: !!cfgPermNetwork?.checked,
      },
      rag: {
        enabled: !!cfgRagEnabled?.checked,
        databasePath: (cfgRagDbPath?.value || 'rag_index.db').trim(),
        folders,
        web,
        maxPages: parseInt(cfgRagMaxPages?.value || '50', 10),
        fileExtensions,
        chunkSize: parseInt(cfgRagChunkSize?.value || '1000', 10),
        chunkOverlap: parseInt(cfgRagChunkOverlap?.value || '150', 10),
        embeddingProvider: cfgRagEmbedProvider?.value || 'embedded',
        embeddingModel: (cfgRagEmbedModel?.value || '').trim(),
        embeddingBaseUrl: (cfgRagEmbedBaseurl?.value || '').trim(),
        embeddingGpuLayers: parseInt(cfgRagEmbedGpulayers?.value || '0', 10),
        embeddingApiKey: (cfgRagEmbedApikey?.value || '').trim(),
        searchMode: cfgRagSearchMode?.value || 'hybrid',
        maxChunks: parseInt(cfgRagMaxChunks?.value || '5', 10),
        minScore: parseFloat(cfgRagMinScore?.value || '0.15'),
      },
    };
  }

  function populateCliSettingsForm(data) {
    if (cliConfigPathEl && data.configPath) {
      cliConfigPathEl.textContent = data.configPath;
      cliConfigPathEl.title = data.configPath;
    }
    if (cfgMultiline && typeof data.multiline === 'boolean') cfgMultiline.checked = data.multiline;
    if (cfgSubmitKey && data.submitKey) cfgSubmitKey.value = data.submitKey;
    if (cfgAutoPasteImages && typeof data.autoPasteImages === 'boolean') cfgAutoPasteImages.checked = data.autoPasteImages;

    if (cfgPlanning && typeof data.planning === 'boolean') cfgPlanning.checked = data.planning;
    if (cfgCompressionThreshold && typeof data.compressionThreshold === 'number') cfgCompressionThreshold.value = data.compressionThreshold;
    if (cfgMaxToolIterations && typeof data.maxToolIterations === 'number') cfgMaxToolIterations.value = data.maxToolIterations;
    if (cfgProgressiveTools && data.progressiveTools) cfgProgressiveTools.value = data.progressiveTools;
    if (cfgCompactTools && typeof data.compactTools === 'boolean') cfgCompactTools.checked = data.compactTools;

    if (cfgMaxTurns && typeof data.maxTurns === 'number') cfgMaxTurns.value = data.maxTurns;
    if (cfgMaxSizeMb && typeof data.maxSizeMb === 'number') cfgMaxSizeMb.value = data.maxSizeMb;
    if (cfgAutoSave && typeof data.autoSave === 'boolean') cfgAutoSave.checked = data.autoSave;

    if (data.permissions) {
      if (cfgPermRead && typeof data.permissions.autoApproveRead === 'boolean') cfgPermRead.checked = data.permissions.autoApproveRead;
      if (cfgPermWrite && typeof data.permissions.autoApproveWrite === 'boolean') cfgPermWrite.checked = data.permissions.autoApproveWrite;
      if (cfgPermExecute && typeof data.permissions.autoApproveExecute === 'boolean') cfgPermExecute.checked = data.permissions.autoApproveExecute;
      if (cfgPermNetwork && typeof data.permissions.autoApproveNetwork === 'boolean') cfgPermNetwork.checked = data.permissions.autoApproveNetwork;
    }

    if (data.rag) {
      const r = data.rag;
      if (cfgRagEnabled && typeof r.enabled === 'boolean') cfgRagEnabled.checked = r.enabled;
      if (cfgRagDbPath && r.databasePath !== undefined) cfgRagDbPath.value = r.databasePath;
      if (cfgRagFolders && Array.isArray(r.folders)) cfgRagFolders.value = r.folders.join('\n');
      if (cfgRagWeb && Array.isArray(r.web)) cfgRagWeb.value = r.web.join('\n');
      if (cfgRagMaxPages && typeof r.maxPages === 'number') cfgRagMaxPages.value = r.maxPages;
      if (cfgRagExtensions && Array.isArray(r.fileExtensions)) cfgRagExtensions.value = r.fileExtensions.join(', ');
      if (cfgRagChunkSize && typeof r.chunkSize === 'number') cfgRagChunkSize.value = r.chunkSize;
      if (cfgRagChunkOverlap && typeof r.chunkOverlap === 'number') cfgRagChunkOverlap.value = r.chunkOverlap;
      if (cfgRagEmbedProvider && r.embeddingProvider) cfgRagEmbedProvider.value = r.embeddingProvider;
      if (cfgRagEmbedModel && r.embeddingModel !== undefined) cfgRagEmbedModel.value = r.embeddingModel;
      if (cfgRagEmbedBaseurl && r.embeddingBaseUrl !== undefined) cfgRagEmbedBaseurl.value = r.embeddingBaseUrl;
      if (cfgRagEmbedGpulayers && typeof r.embeddingGpuLayers === 'number') cfgRagEmbedGpulayers.value = r.embeddingGpuLayers;
      if (cfgRagEmbedApikey && r.embeddingApiKey !== undefined) cfgRagEmbedApikey.value = r.embeddingApiKey;
      if (cfgRagSearchMode && r.searchMode) cfgRagSearchMode.value = r.searchMode;
      if (cfgRagMaxChunks && typeof r.maxChunks === 'number') cfgRagMaxChunks.value = r.maxChunks;
      if (cfgRagMinScore && typeof r.minScore === 'number') cfgRagMinScore.value = r.minScore;
      const isRagOk = !!r.enabled && ((Array.isArray(r.folders) && r.folders.length > 0) || (Array.isArray(r.web) && r.web.length > 0));
      updateRagModeOption(isRagOk);
    }

    if (cfgSaveStatus) {
      cfgSaveStatus.textContent = data.savedAt
        ? `✔ Saved to config.yaml & reloaded (${data.savedAt})`
        : '✔ Synchronized with config.yaml';
      cfgSaveStatus.className = 'hint-status success';
    }
  }

  // Auto-save whenever any setting input/checkbox/select changes in #panel-settings
  if (panelSettings) {
    const allSettingInputs = panelSettings.querySelectorAll('input, select, textarea');
    allSettingInputs.forEach((el) => {
      el.addEventListener('change', () => {
        const config = collectCliSettingsFromForm();
        vscode.postMessage({ type: 'save_cli_config', config, silent: true });
      });
    });
  }

  if (btnSaveCliSettings) {
    btnSaveCliSettings.addEventListener('click', () => {
      const config = collectCliSettingsFromForm();
      vscode.postMessage({ type: 'save_cli_config', config, silent: false });
      btnSaveCliSettings.textContent = '✓ Saved & Synced!';
      setTimeout(() => {
        if (btnSaveCliSettings) btnSaveCliSettings.textContent = '💾 Save & Sync Settings';
      }, 2000);
    });
  }


  // Quick attach button in Chat tab
  if (quickAttachBtn) {
    quickAttachBtn.addEventListener('click', () => {
      window.switchTab('skills');
    });
  }

  // Restart Agent Button
  const restartAgentBtn = document.getElementById('restart-agent-btn');
  if (restartAgentBtn) {
    restartAgentBtn.addEventListener('click', () => {
      statusBadge.textContent = 'Restarting...';
      statusBadge.className = 'badge';
      vscode.postMessage({ type: 'restart_agent' });
    });
  }

  // Gear Button: switch directly to LLM Settings tab
  if (gearBtn) {
    gearBtn.addEventListener('click', () => {
      window.switchTab('llms');
    });
  }

  // --- Chat Event Listeners ---
  sendBtn.addEventListener('click', submitPrompt);
  promptInput.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) {
      e.preventDefault();
      submitPrompt();
    }
  });

  clearBtn.addEventListener('click', () => {
    vscode.postMessage({ type: 'clear' });
    messagesContainer.innerHTML = '';
    currentAssistantBubble = null;
  });

  function startNewChatSession() {
    vscode.postMessage({ type: 'new_session' });
    messagesContainer.innerHTML = '';
    currentAssistantBubble = null;
    setActivity(false);
    if (sessionHistoryModal) sessionHistoryModal.classList.add('hidden');
    window.switchTab('chat');
  }

  if (newSessionBtn) {
    newSessionBtn.addEventListener('click', startNewChatSession);
  }
  if (memoryNewSessionBtn) {
    memoryNewSessionBtn.addEventListener('click', startNewChatSession);
  }
  if (modalNewSessionBtn) {
    modalNewSessionBtn.addEventListener('click', startNewChatSession);
  }

  if (historyBtn) {
    historyBtn.addEventListener('click', () => {
      if (sessionHistoryModal) {
        sessionHistoryModal.classList.remove('hidden');
      }
      vscode.postMessage({ type: 'list_sessions' });
    });
  }
  if (sessionHistoryClose) {
    sessionHistoryClose.addEventListener('click', () => sessionHistoryModal.classList.add('hidden'));
  }
  if (sessionHistoryCloseBtn) {
    sessionHistoryCloseBtn.addEventListener('click', () => sessionHistoryModal.classList.add('hidden'));
  }
  if (refreshSessionsBtn) {
    refreshSessionsBtn.addEventListener('click', () => vscode.postMessage({ type: 'list_sessions' }));
  }
  if (modalRefreshSessionsBtn) {
    modalRefreshSessionsBtn.addEventListener('click', () => vscode.postMessage({ type: 'list_sessions' }));
  }

  function renderRestoredSessionMessages(messages, isTurnActive, forceReplace) {
    if (!Array.isArray(messages)) return;
    const hasExistingMessages = messagesContainer.querySelectorAll('.message, .tool-card').length > 0;
    if (hasExistingMessages && !forceReplace) {
      if (isTurnActive && !isGenerating) {
        setActivity(true, 'Agent is processing...');
      }
      return;
    }

    if (messages.length === 0 && !forceReplace) {
      return;
    }

    messagesContainer.innerHTML = '';
    currentAssistantBubble = null;

    messages.forEach((m) => {
      const role = m.role || '';
      const content = m.content || '';
      if (role === 'user') {
        if (content) {
          appendUserMessage(content);
          currentAssistantBubble = null;
        }
      } else if (role === 'tool') {
        renderToolCard({
          tool: m.toolName || 'tool',
          output: content,
        });
        currentAssistantBubble = null;
      } else if (role === 'assistant') {
        if (Array.isArray(m.toolCalls) && m.toolCalls.length > 0 && !content) {
          // Tool call invocation turn; tool result cards follow
        } else if (content) {
          currentAssistantBubble = null;
          const bubble = getOrCreateAssistantBubble();
          bubble.innerHTML = formatSimpleMarkdown(content);
          currentAssistantBubble = null;
        }
      }
    });

    if (isTurnActive) {
      setActivity(true, 'Agent is processing...');
    } else {
      setActivity(false);
    }
    scrollToBottom();
  }

  function renderSessionsIntoContainer(container, sessions, activeSessionId) {
    if (!container) return;
    if (!sessions || sessions.length === 0) {
      container.innerHTML = '<div class="empty-state">No saved chat sessions found in .tealkit/sessions yet. Sessions are saved automatically after each prompt turn.</div>';
      return;
    }
    container.innerHTML = '';
    sessions.forEach((s) => {
      const isAct = s.isActive || (activeSessionId && s.id === activeSessionId);
      const card = document.createElement('div');
      card.className = `config-card ${isAct ? 'is-default' : ''}`;
      const rawTime = s.updatedAt || s.createdAt || '';
      const d = new Date(rawTime);
      const timeStr = isNaN(d.getTime()) ? rawTime : d.toLocaleString();
      const title = s.title || s.id || 'Chat Session';
      const turns = s.turnCount || s.messageCount || 0;

      card.innerHTML = `
        <div class="card-title-row">
          <div class="card-title-left">
            <span class="card-name">💬 ${escapeHtml(title)}</span>
            ${isAct ? '<span class="card-badge default">ACTIVE</span>' : ''}
            <span class="card-badge">${turns} turns</span>
          </div>
        </div>
        <div class="card-details">
          <div class="card-row"><span class="card-label">Updated:</span><span class="card-val">${escapeHtml(timeStr)}</span></div>
          <div class="card-row"><span class="card-label">File:</span><span class="card-val">${escapeHtml(s.fileName || s.id || '')}</span></div>
        </div>
        <div class="card-actions">
          <button class="card-action-btn clone-btn load-session-btn" data-path="${escapeHtml(s.path)}">▶ Load / Continue</button>
          <button class="card-action-btn open-session-btn" data-path="${escapeHtml(s.path)}">📄 Open JSON</button>
          <button class="card-action-btn delete delete-session-btn" data-path="${escapeHtml(s.path)}">🗑 Delete</button>
        </div>
      `;

      card.querySelector('.load-session-btn').addEventListener('click', () => {
        explicitSessionLoadRequested = true;
        vscode.postMessage({ type: 'load_session', path: s.path });
        if (sessionHistoryModal) sessionHistoryModal.classList.add('hidden');
        window.switchTab('chat');
      });

      card.querySelector('.open-session-btn').addEventListener('click', () => {
        vscode.postMessage({ type: 'open_file', filePath: s.path });
      });

      card.querySelector('.delete-session-btn').addEventListener('click', () => {
        if (confirm(`Delete saved session "${title}"?`)) {
          vscode.postMessage({ type: 'delete_session', path: s.path });
        }
      });

      container.appendChild(card);
    });
  }

  function renderSavedSessionsList(sessions, activeSessionId) {
    renderSessionsIntoContainer(sessionHistoryListEl, sessions, activeSessionId);
    renderSessionsIntoContainer(savedSessionsListEl, sessions, activeSessionId);
  }

  tasksBtn.addEventListener('click', () => {
    vscode.postMessage({ type: 'open_tasks' });
  });

  cancelBtn.addEventListener('click', () => {
    vscode.postMessage({ type: 'cancel' });
    setActivity(false);
  });

  modeSelect.addEventListener('change', (e) => {
    vscode.postMessage({ type: 'set_mode', mode: e.target.value });
  });

  modelSelect.addEventListener('change', (e) => {
    activeSelectedProfile = e.target.value;
    vscode.postMessage({ type: 'set_model', model: e.target.value });
  });

  window.sendQuickPrompt = function (text) {
    promptInput.value = text;
    promptInput.focus();
    if (!text.endsWith(' ')) {
      submitPrompt();
    }
  };

  window.openTasksFile = function () {
    vscode.postMessage({ type: 'open_tasks' });
  };

  function submitPrompt() {
    const raw = promptInput.value.trim();
    if (!raw) return;

    if (isGenerating) {
      vscode.postMessage({ type: 'cancel' });
      setActivity(false);
    }

    // Handle slash commands in input
    if (raw === '/archive') {
      promptInput.value = '';
      vscode.postMessage({ type: 'archive_memory' });
      appendUserMessage('/archive');
      return;
    }

    if (raw.startsWith('/skill attach ')) {
      const sName = raw.substring(14).trim();
      promptInput.value = '';
      vscode.postMessage({ type: 'attach_skill', name: sName });
      appendUserMessage(raw);
      return;
    }

    if (raw.startsWith('/skill detach ')) {
      const sName = raw.substring(14).trim();
      promptInput.value = '';
      vscode.postMessage({ type: 'detach_skill', name: sName });
      appendUserMessage(raw);
      return;
    }

    if (raw === '/skills') {
      promptInput.value = '';
      window.switchTab('skills');
      return;
    }

    appendUserMessage(raw);
    promptInput.value = '';
    vscode.postMessage({ type: 'prompt', text: raw });
    setActivity(true, 'Agent thinking...');
  }

  let activityTimer = null;
  let activityStart = 0;
  let baseActivityText = '';

  function setActivity(active, text) {
    isGenerating = active;
    if (activityTimer) {
      clearInterval(activityTimer);
      activityTimer = null;
    }
    if (active) {
      activityBar.classList.remove('hidden');
      baseActivityText = text || 'Agent thinking...';
      activityStart = Date.now();
      activityText.innerText = baseActivityText;
      activityTimer = setInterval(() => {
        const elapsed = Math.floor((Date.now() - activityStart) / 1000);
        activityText.innerText = `${baseActivityText} (${elapsed}s)`;
      }, 1000);
    } else {
      activityBar.classList.add('hidden');
    }
  }

  // Clipboard copy helper
  window.copyToClipboard = function (text, btn) {
    if (!text) return;
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(() => showCopied(btn)).catch(() => fallbackCopy(text, btn));
    } else {
      fallbackCopy(text, btn);
    }
  };

  function fallbackCopy(text, btn) {
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    try {
      document.execCommand('copy');
      showCopied(btn);
    } catch (_) {}
    document.body.removeChild(ta);
  }

  function showCopied(btn) {
    if (!btn) return;
    const original = btn.innerHTML;
    btn.innerHTML = `✓ <span>Copied!</span>`;
    btn.classList.add('copied');
    setTimeout(() => {
      btn.innerHTML = original;
      btn.classList.remove('copied');
    }, 1800);
  }

  const COPY_SVG = `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path></svg>`;

  function createCopyButton(getTextFn, label = 'Copy') {
    const btn = document.createElement('button');
    btn.className = 'msg-copy-btn';
    btn.title = 'Copy to clipboard';
    btn.innerHTML = `${COPY_SVG}<span>${escapeHtml(label)}</span>`;
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      const text = getTextFn();
      if (!text) return;
      window.copyToClipboard(text, btn);
    });
    return btn;
  }

  function appendUserMessage(text) {
    const msgDiv = document.createElement('div');
    msgDiv.className = 'message user';
    const bubble = document.createElement('div');
    bubble.className = 'bubble';
    bubble.innerHTML = escapeHtml(text);
    msgDiv.appendChild(bubble);

    const footer = document.createElement('div');
    footer.className = 'msg-footer';
    const copyBtn = createCopyButton(() => text, 'Copy');
    footer.appendChild(copyBtn);
    msgDiv.appendChild(footer);

    messagesContainer.appendChild(msgDiv);
    scrollToBottom();
  }

  function getOrCreateAssistantBubble() {
    if (!currentAssistantBubble) {
      const msgDiv = document.createElement('div');
      msgDiv.className = 'message assistant';
      const bubble = document.createElement('div');
      bubble.className = 'bubble';
      msgDiv.appendChild(bubble);

      const footer = document.createElement('div');
      footer.className = 'msg-footer';
      const copyBtn = createCopyButton(() => bubble.innerText || bubble.textContent || '', 'Copy');
      footer.appendChild(copyBtn);
      msgDiv.appendChild(footer);

      messagesContainer.appendChild(msgDiv);
      currentAssistantBubble = bubble;
    }
    return currentAssistantBubble;
  }

  function escapeHtml(str) {
    if (str === null || str === undefined) return '';
    const p = document.createElement('p');
    p.textContent = String(str);
    return p.innerHTML;
  }

  function formatSimpleMarkdown(text) {
    let html = escapeHtml(text);
    html = html.replace(/\*\*(.*?)\*\*/g, '<strong>$1</strong>');
    html = html.replace(/`([^`]+)`/g, '<code>$1</code>');
    html = html.replace(/\n/g, '<br/>');
    return html;
  }

  function scrollToBottom() {
    messagesContainer.scrollTop = messagesContainer.scrollHeight;
  }

  function updateAttachedSkillsChips(skills) {
    currentActiveSkills = skills || [];
    if (!attachedSkillsChips) return;

    if (currentActiveSkills.length === 0) {
      attachedSkillsChips.innerHTML = '<span class="no-skills-text">(none attached)</span>';
      return;
    }

    attachedSkillsChips.innerHTML = '';
    currentActiveSkills.forEach((s) => {
      const chip = document.createElement('span');
      chip.className = 'skill-chip';
      chip.innerHTML = `🧩 ${escapeHtml(s)} <span class="skill-chip-remove" title="Detach skill">✕</span>`;
      chip.querySelector('.skill-chip-remove').addEventListener('click', (e) => {
        e.stopPropagation();
        vscode.postMessage({ type: 'detach_skill', name: s });
      });
      attachedSkillsChips.appendChild(chip);
    });
  }

  // --- LLM Panel Logic ---
  openLlmFileBtn.addEventListener('click', () => {
    if (activeLlmFilePath) {
      vscode.postMessage({ type: 'open_file', filePath: activeLlmFilePath });
    }
  });

  refreshLlmBtn.addEventListener('click', () => {
    vscode.postMessage({ type: 'get_llm_config' });
  });

  addLlmBtn.addEventListener('click', () => {
    editingLlmOriginalName = null;
    llmModalTitle.textContent = 'Add LLM Profile';
    llmInputName.value = '';
    llmInputName.disabled = false;
    llmInputProvider.value = 'openai_compatible';
    llmInputModel.value = '';
    llmInputBaseUrl.value = '';
    llmInputApiKey.value = '';
    llmInputDefault.checked = false;
    if (llmInputTemp) llmInputTemp.value = '0.2';
    if (llmInputMaxTokens) llmInputMaxTokens.value = '8192';
    if (llmInputContextSize) llmInputContextSize.value = '';
    if (llmInputTopP) llmInputTopP.value = '';
    if (llmInputTopK) llmInputTopK.value = '';
    if (llmInputRepeatPenalty) llmInputRepeatPenalty.value = '';
    if (llmInputIsSlm) llmInputIsSlm.checked = false;
    if (llmInputThinking) llmInputThinking.checked = false;
    if (llmInputStreaming) llmInputStreaming.checked = false;
    clearLlmFeedback();
    llmModal.classList.remove('hidden');
  });

  if (llmBtnLoadModels) {
    llmBtnLoadModels.addEventListener('click', () => {
      llmModelsStatus.textContent = 'Fetching available models from provider...';
      llmModelsStatus.className = 'hint-status loading';
      vscode.postMessage({
        type: 'fetch_provider_models',
        provider: llmInputProvider.value,
        baseUrl: llmInputBaseUrl.value.trim(),
        apiKey: llmInputApiKey.value.trim(),
      });
    });
  }

  if (llmBtnTestApi) {
    llmBtnTestApi.addEventListener('click', () => {
      llmTestResult.textContent = 'Connecting...';
      llmTestResult.className = 'test-result-badge testing';
      vscode.postMessage({
        type: 'test_llm_api',
        provider: llmInputProvider.value,
        model: llmInputModel.value.trim(),
        baseUrl: llmInputBaseUrl.value.trim(),
        apiKey: llmInputApiKey.value.trim(),
      });
    });
  }

  llmModalClose.addEventListener('click', () => llmModal.classList.add('hidden'));
  llmModalCancel.addEventListener('click', () => llmModal.classList.add('hidden'));

  toggleApiKeyVisibility.addEventListener('click', () => {
    if (llmInputApiKey.type === 'password') {
      llmInputApiKey.type = 'text';
      toggleApiKeyVisibility.textContent = '🔒';
    } else {
      llmInputApiKey.type = 'password';
      toggleApiKeyVisibility.textContent = '👁';
    }
  });

  llmModalSave.addEventListener('click', () => {
    const name = llmInputName.value.trim();
    const provider = llmInputProvider.value;
    const model = llmInputModel.value.trim();
    const baseUrl = llmInputBaseUrl.value.trim();
    const apiKey = llmInputApiKey.value.trim();
    const isDefault = llmInputDefault.checked;

    if (!name || !model) {
      alert('Profile Name and Model ID are required.');
      return;
    }

    const tempVal = llmInputTemp && llmInputTemp.value ? parseFloat(llmInputTemp.value) : undefined;
    const maxTokensVal = llmInputMaxTokens && llmInputMaxTokens.value ? parseInt(llmInputMaxTokens.value, 10) : undefined;
    const ctxVal = llmInputContextSize && llmInputContextSize.value ? parseInt(llmInputContextSize.value, 10) : undefined;
    const topPVal = llmInputTopP && llmInputTopP.value ? parseFloat(llmInputTopP.value) : undefined;
    const topKVal = llmInputTopK && llmInputTopK.value ? parseInt(llmInputTopK.value, 10) : undefined;
    const repeatVal = llmInputRepeatPenalty && llmInputRepeatPenalty.value ? parseFloat(llmInputRepeatPenalty.value) : undefined;
    const isSlmVal = llmInputIsSlm ? !!llmInputIsSlm.checked : undefined;
    const thinkingVal = llmInputThinking ? !!llmInputThinking.checked : undefined;
    const streamingVal = llmInputStreaming ? !!llmInputStreaming.checked : undefined;

    vscode.postMessage({
      type: 'save_llm_profile',
      originalName: editingLlmOriginalName || undefined,
      profile: {
        name,
        provider,
        model,
        baseUrl: baseUrl || undefined,
        apiKey: apiKey || undefined,
        temperature: tempVal,
        maxTokens: maxTokensVal,
        contextSize: ctxVal,
        topP: topPVal,
        topK: topKVal,
        repeatPenalty: repeatVal,
        isSlm: isSlmVal,
        thinking: thinkingVal,
        useStreaming: streamingVal,
      },
      isDefault,
    });

    llmModal.classList.add('hidden');
  });

  function renderLlmList(data) {
    activeLlmFilePath = data.filePath || '';
    llmFilePathEl.textContent = activeLlmFilePath || '(not resolved)';
    llmFilePathEl.title = activeLlmFilePath;

    const profiles = data.profiles || [];
    const defaultModel = data.defaultModel || '';

    if (profiles.length > 0) {
      const currentSelected = activeSelectedProfile || modelSelect.value;
      modelSelect.innerHTML = '';
      profiles.forEach((p) => {
        const opt = document.createElement('option');
        opt.value = p.name;
        const badge = p.ctxAndPricing ? ` [${p.ctxAndPricing}]` : '';
        opt.textContent = `${p.name} (${p.model || p.provider}${badge})`;
        if (p.name === defaultModel || (!defaultModel && p.name === currentSelected)) {
          opt.selected = true;
        }
        modelSelect.appendChild(opt);
      });
      if (defaultModel) {
        modelSelect.value = (currentSelected && profiles.some(p => p.name === currentSelected)) ? currentSelected : defaultModel;
        activeSelectedProfile = modelSelect.value;
      } else if (currentSelected && profiles.some(p => p.name === currentSelected)) {
        modelSelect.value = currentSelected;
      }
    }

    if (profiles.length === 0) {
      llmListEl.innerHTML = '<div class="empty-state">No LLM profiles configured yet. Click "+ Add Profile" above.</div>';
      return;
    }

    llmListEl.innerHTML = '';
    profiles.forEach((p) => {
      const isDef = p.name === defaultModel || p.isDefault === true;
      const card = document.createElement('div');
      card.className = `config-card ${isDef ? 'is-default' : ''}`;

      const keyDisplay = p.apiKey ? '•••••••• (stored)' : 'From ENV or blank';

      card.innerHTML = `
        <div class="card-title-row">
          <div class="card-title-left">
            <span class="card-name">${escapeHtml(p.name)}</span>
            <span class="card-badge">${escapeHtml(p.provider)}</span>
            ${isDef ? '<span class="card-badge default">DEFAULT</span>' : ''}
            ${p.ctxAndPricing ? `<span class="card-badge ctx-badge">${escapeHtml(p.ctxAndPricing)}</span>` : ''}
          </div>
        </div>
        <div class="card-details">
          <div class="card-row"><span class="card-label">Model:</span><span class="card-val">${escapeHtml(p.model)}</span></div>
          ${p.baseUrl ? `<div class="card-row"><span class="card-label">Base URL:</span><span class="card-val">${escapeHtml(p.baseUrl)}</span></div>` : ''}
          <div class="card-row"><span class="card-label">API Key:</span><span class="card-val">${escapeHtml(keyDisplay)}</span></div>
          <div class="card-row"><span class="card-label">Specs:</span><span class="card-val">${p.ctxAndPricing ? `<strong>[${escapeHtml(p.ctxAndPricing)}]</strong> ` : ''}(temp: ${p.temperature ?? 0.2}, max_tokens: ${p.maxTokens ?? 8192}${p.contextSize ? `, ctx: ${p.contextSize}` : ''}${p.isSlm ? ', SLM' : ''}${p.thinking ? ', Thinking' : ''}${p.useStreaming ? ', Stream' : ''})</span></div>
        </div>
        <div class="card-actions">
          ${!isDef ? `<button class="card-action-btn set-default-btn" data-name="${escapeHtml(p.name)}">Set Default</button>` : ''}
          <button class="card-action-btn edit-btn" data-name="${escapeHtml(p.name)}">Edit</button>
          <button class="card-action-btn clone-btn" data-name="${escapeHtml(p.name)}">Clone</button>
          <button class="card-action-btn delete delete-btn" data-name="${escapeHtml(p.name)}">Delete</button>
        </div>
      `;

      const setDefaultBtn = card.querySelector('.set-default-btn');
      if (setDefaultBtn) {
        setDefaultBtn.addEventListener('click', () => {
          vscode.postMessage({ type: 'set_default_llm_profile', name: p.name });
        });
      }

      card.querySelector('.edit-btn').addEventListener('click', () => {
        editingLlmOriginalName = p.name;
        llmModalTitle.textContent = `Edit Profile: ${p.name}`;
        llmInputName.value = p.name;
        llmInputName.disabled = false;
        llmInputProvider.value = p.provider || 'openai_compatible';
        llmInputModel.value = p.model || '';
        llmInputBaseUrl.value = p.baseUrl || '';
        llmInputApiKey.value = p.apiKey || '';
        llmInputDefault.checked = isDef;
        if (llmInputTemp) llmInputTemp.value = p.temperature !== undefined ? p.temperature : 0.2;
        if (llmInputMaxTokens) llmInputMaxTokens.value = p.maxTokens !== undefined ? p.maxTokens : 8192;
        if (llmInputContextSize) llmInputContextSize.value = p.contextSize || '';
        if (llmInputTopP) llmInputTopP.value = p.topP !== undefined ? p.topP : '';
        if (llmInputTopK) llmInputTopK.value = p.topK !== undefined ? p.topK : '';
        if (llmInputRepeatPenalty) llmInputRepeatPenalty.value = p.repeatPenalty !== undefined ? p.repeatPenalty : '';
        if (llmInputIsSlm) llmInputIsSlm.checked = !!p.isSlm;
        if (llmInputThinking) llmInputThinking.checked = !!p.thinking;
        if (llmInputStreaming) llmInputStreaming.checked = !!p.useStreaming;
        clearLlmFeedback();
        llmModal.classList.remove('hidden');
      });

      card.querySelector('.clone-btn').addEventListener('click', () => {
        editingLlmOriginalName = null;
        llmModalTitle.textContent = `Clone Profile: ${p.name}`;
        llmInputName.value = `${p.name}_copy`;
        llmInputName.disabled = false;
        llmInputProvider.value = p.provider || 'openai_compatible';
        llmInputModel.value = p.model || '';
        llmInputBaseUrl.value = p.baseUrl || '';
        llmInputApiKey.value = p.apiKey || '';
        llmInputDefault.checked = false;
        if (llmInputTemp) llmInputTemp.value = p.temperature !== undefined ? p.temperature : 0.2;
        if (llmInputMaxTokens) llmInputMaxTokens.value = p.maxTokens !== undefined ? p.maxTokens : 8192;
        if (llmInputContextSize) llmInputContextSize.value = p.contextSize || '';
        if (llmInputTopP) llmInputTopP.value = p.topP !== undefined ? p.topP : '';
        if (llmInputTopK) llmInputTopK.value = p.topK !== undefined ? p.topK : '';
        if (llmInputRepeatPenalty) llmInputRepeatPenalty.value = p.repeatPenalty !== undefined ? p.repeatPenalty : '';
        if (llmInputIsSlm) llmInputIsSlm.checked = !!p.isSlm;
        if (llmInputThinking) llmInputThinking.checked = !!p.thinking;
        if (llmInputStreaming) llmInputStreaming.checked = !!p.useStreaming;
        clearLlmFeedback();
        llmModal.classList.remove('hidden');
      });

      card.querySelector('.delete-btn').addEventListener('click', () => {
        if (confirm(`Delete LLM profile "${p.name}"?`)) {
          vscode.postMessage({ type: 'delete_llm_profile', name: p.name });
        }
      });

      llmListEl.appendChild(card);
    });
  }

  // --- MCP Panel Logic ---
  function parseMcpModalInputs() {
    const name = (mcpInputName?.value || '').trim() || 'test-server';
    const command = (mcpInputCommand?.value || '').trim();
    const argsRaw = (mcpInputArgs?.value || '').trim();
    const envRaw = (mcpInputEnv?.value || '').trim();
    const enabled = !!mcpInputEnabled?.checked;
    const args = argsRaw ? argsRaw.split(/\s+/).filter(Boolean) : [];
    let env = {};
    if (envRaw) {
      try {
        env = JSON.parse(envRaw);
      } catch (_) {
        envRaw.split('\n').forEach((line) => {
          const eq = line.indexOf('=');
          if (eq > 0) {
            env[line.slice(0, eq).trim()] = line.slice(eq + 1).trim();
          }
        });
      }
    }
    return { name, command, args, env, enabled };
  }

  function renderMcpToolsResultBox(container, result) {
    if (!container) return;
    container.classList.remove('hidden');
    if (!result.success) {
      container.innerHTML = `<div style="color: #f87171; font-weight: 500;">✖ ${escapeHtml(result.error || 'Failed to connect to MCP server')}</div>`;
      return;
    }
    const tools = result.tools || [];
    if (tools.length === 0) {
      container.innerHTML = `<div style="color: #4ade80;">✔ Connected to server (0 tools reported).</div>`;
      return;
    }
    let html = `<div class="mcp-tools-header"><span>✔ Discovered ${tools.length} Tool${tools.length === 1 ? '' : 's'}</span></div>`;
    tools.forEach((t) => {
      html += `
        <div class="mcp-tool-item">
          <div class="mcp-tool-item-name">🔧 ${escapeHtml(t.name)}</div>
          ${t.description ? `<div class="mcp-tool-item-desc">${escapeHtml(t.description)}</div>` : ''}
        </div>
      `;
    });
    container.innerHTML = html;
  }

  openMcpFileBtn.addEventListener('click', () => {
    if (activeMcpFilePath) {
      vscode.postMessage({ type: 'open_file', filePath: activeMcpFilePath });
    }
  });

  refreshMcpBtn.addEventListener('click', () => {
    vscode.postMessage({ type: 'get_mcp_config' });
  });

  addMcpBtn.addEventListener('click', () => {
    editingMcpOriginalName = null;
    mcpModalTitle.textContent = 'Add MCP Server';
    mcpInputName.value = '';
    mcpInputName.disabled = false;
    mcpInputCommand.value = 'npx';
    mcpInputArgs.value = '';
    mcpInputEnv.value = '';
    mcpInputEnabled.checked = true;
    if (mcpModalToolsResult) {
      mcpModalToolsResult.innerHTML = '';
      mcpModalToolsResult.classList.add('hidden');
    }
    mcpModal.classList.remove('hidden');
  });

  if (mcpBtnTest) {
    mcpBtnTest.addEventListener('click', () => {
      const server = parseMcpModalInputs();
      if (!server.command) {
        alert('Command is required to test MCP server.');
        return;
      }
      if (mcpModalToolsResult) {
        mcpModalToolsResult.classList.remove('hidden');
        mcpModalToolsResult.innerHTML = '<div style="color: #38bdf8;">🔄 Spawning MCP server & querying tools/list...</div>';
      }
      vscode.postMessage({
        type: 'test_mcp_server',
        fromModal: true,
        server,
      });
    });
  }

  mcpModalClose.addEventListener('click', () => mcpModal.classList.add('hidden'));
  mcpModalCancel.addEventListener('click', () => mcpModal.classList.add('hidden'));

  mcpModalSave.addEventListener('click', () => {
    const server = parseMcpModalInputs();
    if (!mcpInputName.value.trim() || !server.command) {
      alert('Server Name and Command are required.');
      return;
    }

    vscode.postMessage({
      type: 'save_mcp_server',
      originalName: editingMcpOriginalName || undefined,
      server,
    });

    mcpModal.classList.add('hidden');
  });

  function renderMcpList(data) {
    activeMcpFilePath = data.filePath || '';
    mcpFilePathEl.textContent = activeMcpFilePath || '(not resolved)';
    mcpFilePathEl.title = activeMcpFilePath;

    const servers = data.servers || [];
    if (servers.length === 0) {
      mcpListEl.innerHTML = '<div class="empty-state">No external MCP servers configured yet. Click "+ Add Server" above.</div>';
      return;
    }

    mcpListEl.innerHTML = '';
    servers.forEach((s) => {
      const card = document.createElement('div');
      card.className = 'config-card';

      const envKeys = Object.keys(s.env || {});
      const envSummary = envKeys.length > 0 ? envKeys.join(', ') : 'None';
      const argsSummary = (s.args || []).join(' ') || '(no args)';
      const safeId = s.name.replace(/[^a-zA-Z0-9_-]/g, '_');

      card.innerHTML = `
        <div class="card-title-row">
          <div class="card-title-left">
            <span class="card-name">${escapeHtml(s.name)}</span>
          </div>
          <label class="switch" title="Toggle active status">
            <input type="checkbox" class="mcp-toggle" ${s.enabled ? 'checked' : ''} data-name="${escapeHtml(s.name)}">
            <span class="slider"></span>
          </label>
        </div>
        <div class="card-details">
          <div class="card-row"><span class="card-label">Command:</span><span class="card-val">${escapeHtml(s.command)}</span></div>
          <div class="card-row"><span class="card-label">Args:</span><span class="card-val">${escapeHtml(argsSummary)}</span></div>
          <div class="card-row"><span class="card-label">Env:</span><span class="card-val">${escapeHtml(envSummary)}</span></div>
        </div>
        <div class="card-actions">
          <button class="card-action-btn clone-btn test-mcp-btn" data-name="${escapeHtml(s.name)}">🔍 Test / Show Tools</button>
          <button class="card-action-btn edit-mcp-btn" data-name="${escapeHtml(s.name)}">Edit</button>
          <button class="card-action-btn delete delete-mcp-btn" data-name="${escapeHtml(s.name)}">Delete</button>
        </div>
        <div id="mcp-card-tools-${safeId}" class="mcp-card-tools hidden"></div>
      `;

      card.querySelector('.mcp-toggle').addEventListener('change', (e) => {
        vscode.postMessage({
          type: 'toggle_mcp_server',
          name: s.name,
          enabled: e.target.checked,
        });
      });

      card.querySelector('.test-mcp-btn').addEventListener('click', () => {
        const toolsBox = card.querySelector(`#mcp-card-tools-${safeId}`);
        if (toolsBox) {
          toolsBox.classList.remove('hidden');
          toolsBox.innerHTML = '<div style="color: #38bdf8;">🔄 Launching MCP server & querying tools...</div>';
        }
        vscode.postMessage({
          type: 'test_mcp_server',
          fromModal: false,
          server: s,
        });
      });

      card.querySelector('.edit-mcp-btn').addEventListener('click', () => {
        editingMcpOriginalName = s.name;
        mcpModalTitle.textContent = `Edit MCP Server: ${s.name}`;
        mcpInputName.value = s.name;
        mcpInputName.disabled = false;
        mcpInputCommand.value = s.command || '';
        mcpInputArgs.value = (s.args || []).join(' ');
        mcpInputEnv.value = s.env ? JSON.stringify(s.env, null, 2) : '';
        mcpInputEnabled.checked = s.enabled !== false;
        if (mcpModalToolsResult) {
          mcpModalToolsResult.innerHTML = '';
          mcpModalToolsResult.classList.add('hidden');
        }
        mcpModal.classList.remove('hidden');
      });

      card.querySelector('.delete-mcp-btn').addEventListener('click', () => {
        if (confirm(`Delete MCP server "${s.name}"?`)) {
          vscode.postMessage({ type: 'delete_mcp_server', name: s.name });
        }
      });

      mcpListEl.appendChild(card);
    });
  }

  // --- Skills Panel Logic (pic2) ---
  if (openSkillsFolderBtn) {
    openSkillsFolderBtn.addEventListener('click', () => {
      if (activeSkillsDirPath) {
        vscode.postMessage({ type: 'open_file', filePath: activeSkillsDirPath });
      }
    });
  }

  if (refreshSkillsBtn) {
    refreshSkillsBtn.addEventListener('click', () => {
      vscode.postMessage({ type: 'get_skills' });
    });
  }

  if (addSkillBtn) {
    addSkillBtn.addEventListener('click', () => {
      skillInputName.value = '';
      skillInputDesc.value = '';
      skillInputPrompt.value = '';
      skillModal.classList.remove('hidden');
    });
  }

  if (skillModalClose) skillModalClose.addEventListener('click', () => skillModal.classList.add('hidden'));
  if (skillModalCancel) skillModalCancel.addEventListener('click', () => skillModal.classList.add('hidden'));

  if (skillModalSave) {
    skillModalSave.addEventListener('click', () => {
      const name = skillInputName.value.trim();
      const desc = skillInputDesc.value.trim();
      const prompt = skillInputPrompt.value.trim();

      if (!name) {
        alert('Skill name is required.');
        return;
      }

      const content = `---
name: ${name}
description: ${desc}
version: 1.0.0
system_prompt: |
  ${prompt.replace(/\n/g, '\n  ')}
---
`;

      vscode.postMessage({ type: 'save_skill', name, content });
      skillModal.classList.add('hidden');
    });
  }

  function renderSkillsList(data) {
    activeSkillsDirPath = data.directory || '';
    if (skillsDirPathEl) {
      skillsDirPathEl.textContent = activeSkillsDirPath || '(not resolved)';
      skillsDirPathEl.title = activeSkillsDirPath;
    }

    const skills = data.skills || [];
    const active = data.activeSkills || currentActiveSkills || [];
    updateAttachedSkillsChips(active);

    if (!skillsListEl) return;

    if (skills.length === 0) {
      skillsListEl.innerHTML = '<div class="empty-state">No skills found. Click "+ New Skill" above.</div>';
      return;
    }

    skillsListEl.innerHTML = '';
    skills.forEach((s) => {
      const isAtt = active.includes(s.name);
      const card = document.createElement('div');
      card.className = `config-card ${isAtt ? 'is-default' : ''}`;

      card.innerHTML = `
        <div class="card-title-row">
          <div class="card-title-left">
            <span class="card-name">🧩 ${escapeHtml(s.name)}</span>
            ${isAtt ? '<span class="card-badge attached">ATTACHED</span>' : '<span class="card-badge">Available</span>'}
          </div>
        </div>
        <div class="skill-desc">${escapeHtml(s.description || '(no description)')}</div>
        <div class="card-actions">
          ${
            isAtt
              ? `<button class="card-action-btn detach-skill-btn" style="color: #f87171;" data-name="${escapeHtml(s.name)}">✕ Detach</button>`
              : `<button class="card-action-btn attach-skill-btn" style="color: #34d399;" data-name="${escapeHtml(s.name)}">➕ Attach to Session</button>`
          }
          <button class="card-action-btn open-skill-btn" data-path="${escapeHtml(s.path)}">📄 Open in Editor</button>
        </div>
      `;

      const attachBtn = card.querySelector('.attach-skill-btn');
      if (attachBtn) {
        attachBtn.addEventListener('click', () => {
          vscode.postMessage({ type: 'attach_skill', name: s.name });
        });
      }

      const detachBtn = card.querySelector('.detach-skill-btn');
      if (detachBtn) {
        detachBtn.addEventListener('click', () => {
          vscode.postMessage({ type: 'detach_skill', name: s.name });
        });
      }

      const openBtn = card.querySelector('.open-skill-btn');
      if (openBtn) {
        openBtn.addEventListener('click', () => {
          vscode.postMessage({ type: 'open_file', filePath: s.path });
        });
      }

      skillsListEl.appendChild(card);
    });
  }

  // --- Memory Archive Panel Logic (pic1) ---
  if (archiveNowBtn) {
    archiveNowBtn.addEventListener('click', () => {
      vscode.postMessage({ type: 'archive_memory' });
    });
  }

  if (refreshMemoryBtn) {
    refreshMemoryBtn.addEventListener('click', () => {
      vscode.postMessage({ type: 'get_memory_archives' });
    });
  }

  function renderMemoryArchives(archives) {
    if (!memoryListEl) return;

    if (!archives || archives.length === 0) {
      memoryListEl.innerHTML = '<div class="empty-state">No archived memories yet. Active sessions are automatically archived or click "🧠 Archive Now" above.</div>';
      return;
    }

    memoryListEl.innerHTML = '';
    archives.forEach((a) => {
      const card = document.createElement('div');
      card.className = 'memory-card';

      const d = new Date(a.timestamp);
      const timeStr = isNaN(d.getTime()) ? a.timestamp : d.toLocaleString();

      card.innerHTML = `
        <div class="memory-card-header">
          <span class="memory-id">🧠 ${escapeHtml(a.archiveId)}</span>
          <span class="memory-turns-badge">${a.turnCount} turns</span>
        </div>
        <div class="card-details">
          <div class="card-row"><span class="card-label">Saved:</span><span class="card-val">${escapeHtml(timeStr)}</span></div>
        </div>
        <div class="card-actions">
          <button class="card-action-btn open-memory-btn" data-path="${escapeHtml(a.path)}">📄 Open Archive</button>
        </div>
      `;

      card.querySelector('.open-memory-btn').addEventListener('click', () => {
        vscode.postMessage({ type: 'open_file', filePath: a.path });
      });

      memoryListEl.appendChild(card);
    });
  }

  // --- Server Panel Logic ---
  if (openServerFileBtn) {
    openServerFileBtn.addEventListener('click', () => {
      if (activeServerFilePath) {
        vscode.postMessage({ type: 'open_file', filePath: activeServerFilePath });
      }
    });
  }

  if (refreshServerBtn) {
    refreshServerBtn.addEventListener('click', () => {
      vscode.postMessage({ type: 'get_server_config' });
    });
  }

  if (refreshWorkflowsBtn) {
    refreshWorkflowsBtn.addEventListener('click', () => {
      vscode.postMessage({ type: 'list_workflows' });
    });
  }

  if (addServerBtn) {
    addServerBtn.addEventListener('click', () => {
      editingServerOriginalName = null;
      if (serverModalTitle) serverModalTitle.textContent = 'Add Server Profile';
      serverInputName.value = '';
      serverInputName.disabled = false;
      serverInputUrl.value = 'http://localhost:7771';
      serverInputApiKey.value = '';
      serverInputActive.checked = true;
      if (serverModalTestResult) {
        serverModalTestResult.textContent = '';
        serverModalTestResult.className = 'test-result-badge';
      }
      serverModal.classList.remove('hidden');
    });
  }

  if (serverBtnTest) {
    serverBtnTest.addEventListener('click', () => {
      const url = (serverInputUrl?.value || '').trim();
      const apiKey = (serverInputApiKey?.value || '').trim();
      const name = (serverInputName?.value || '').trim();
      if (!url) {
        alert('Server URL is required.');
        return;
      }
      if (serverModalTestResult) {
        serverModalTestResult.textContent = '🔄 Testing connection...';
        serverModalTestResult.className = 'test-result-badge testing';
      }
      vscode.postMessage({
        type: 'test_server_connection',
        fromModal: true,
        name,
        url,
        apiKey,
      });
    });
  }

  if (serverModalClose) serverModalClose.addEventListener('click', () => serverModal.classList.add('hidden'));
  if (serverModalCancel) serverModalCancel.addEventListener('click', () => serverModal.classList.add('hidden'));

  if (serverModalSave) {
    serverModalSave.addEventListener('click', () => {
      const name = serverInputName.value.trim();
      const url = serverInputUrl.value.trim();
      const apiKey = serverInputApiKey.value.trim();
      const isActive = serverInputActive.checked;

      if (!name || !url) {
        alert('Server name and URL are required.');
        return;
      }

      vscode.postMessage({
        type: 'save_server_profile',
        originalName: editingServerOriginalName || undefined,
        profile: { name, url, apiKey, isActive },
      });

      serverModal.classList.add('hidden');
    });
  }

  function renderServerProfiles(data) {
    activeServerFilePath = data.filePath || '';
    if (serverConfigPathEl) {
      serverConfigPathEl.textContent = activeServerFilePath || '(not resolved)';
      serverConfigPathEl.title = activeServerFilePath;
    }

    const profiles = data.profiles || [];
    if (!serverProfilesListEl) return;

    if (profiles.length === 0) {
      serverProfilesListEl.innerHTML = '<div class="empty-state">No servers configured in server.yaml.</div>';
      return;
    }

    serverProfilesListEl.innerHTML = '';
    profiles.forEach((p) => {
      const card = document.createElement('div');
      card.className = `config-card ${p.isActive ? 'is-default' : ''}`;
      const safeId = p.name.replace(/[^a-zA-Z0-9_-]/g, '_');

      card.innerHTML = `
        <div class="card-title-row">
          <div class="card-title-left">
            <span class="card-name">☁️ ${escapeHtml(p.name)}</span>
            ${p.isActive ? '<span class="card-badge default">ACTIVE</span>' : ''}
          </div>
        </div>
        <div class="card-details">
          <div class="card-row"><span class="card-label">URL:</span><span class="card-val">${escapeHtml(p.url)}</span></div>
          <div class="card-row"><span class="card-label">API Key:</span><span class="card-val">${p.apiKey ? '••••••••' : '(none)'}</span></div>
        </div>
        <div id="srv-test-status-${safeId}" class="server-card-status hidden"></div>
        <div class="card-actions">
          ${!p.isActive ? `<button class="card-action-btn set-active-server-btn" data-name="${escapeHtml(p.name)}">Set Active</button>` : ''}
          <button class="card-action-btn clone-btn test-server-btn" data-name="${escapeHtml(p.name)}">🔌 Test</button>
          <button class="card-action-btn edit-server-btn" data-name="${escapeHtml(p.name)}">Edit</button>
          <button class="card-action-btn delete delete-server-btn" data-name="${escapeHtml(p.name)}">Delete</button>
        </div>
      `;

      const setActBtn = card.querySelector('.set-active-server-btn');
      if (setActBtn) {
        setActBtn.addEventListener('click', () => {
          vscode.postMessage({ type: 'activate_server_profile', name: p.name });
        });
      }

      card.querySelector('.test-server-btn').addEventListener('click', () => {
        const statusEl = card.querySelector(`#srv-test-status-${safeId}`);
        if (statusEl) {
          statusEl.className = 'server-card-status testing';
          statusEl.textContent = '🔄 Testing connection...';
        }
        vscode.postMessage({
          type: 'test_server_connection',
          fromModal: false,
          name: p.name,
          url: p.url,
          apiKey: p.apiKey,
        });
      });

      card.querySelector('.edit-server-btn').addEventListener('click', () => {
        editingServerOriginalName = p.name;
        if (serverModalTitle) serverModalTitle.textContent = `Edit Server Profile: ${p.name}`;
        serverInputName.value = p.name;
        serverInputName.disabled = false;
        serverInputUrl.value = p.url || '';
        serverInputApiKey.value = p.apiKey || '';
        serverInputActive.checked = !!p.isActive;
        if (serverModalTestResult) {
          serverModalTestResult.textContent = '';
          serverModalTestResult.className = 'test-result-badge';
        }
        serverModal.classList.remove('hidden');
      });

      card.querySelector('.delete-server-btn').addEventListener('click', () => {
        if (confirm(`Delete server profile "${p.name}"?`)) {
          vscode.postMessage({ type: 'delete_server_profile', name: p.name });
        }
      });

      serverProfilesListEl.appendChild(card);
    });
  }

  function startWorkflowPolling(wfId) {
    if (!workflowStateMap[wfId]) workflowStateMap[wfId] = {};
    if (workflowStateMap[wfId].pollTimer) {
      clearInterval(workflowStateMap[wfId].pollTimer);
    }
    workflowStateMap[wfId].pollTimer = setInterval(() => {
      vscode.postMessage({ type: 'get_workflow_status', id: wfId });
    }, 2500);
  }

  function stopWorkflowPolling(wfId) {
    if (workflowStateMap[wfId] && workflowStateMap[wfId].pollTimer) {
      clearInterval(workflowStateMap[wfId].pollTimer);
      workflowStateMap[wfId].pollTimer = null;
    }
  }

  function updateWorkflowStatusUI(wfId, stateObj) {
    const badgeEl = document.getElementById(`wf-status-badge-${wfId}`);
    const stopBtn = document.getElementById(`wf-stop-btn-${wfId}`);
    const runBtn = document.getElementById(`wf-run-btn-${wfId}`);
    if (!badgeEl) return;

    if (stateObj.running) {
      badgeEl.className = 'wf-status-badge running';
      badgeEl.textContent = stateObj.runId ? `🔄 RUNNING (${stateObj.runId.slice(0, 8)})` : '🔄 RUNNING...';
      if (stopBtn) stopBtn.classList.remove('hidden');
      if (runBtn) runBtn.disabled = true;
    } else {
      if (stopBtn) stopBtn.classList.add('hidden');
      if (runBtn) runBtn.disabled = false;
      if (stateObj.cancelled) {
        badgeEl.className = 'wf-status-badge failed';
        badgeEl.textContent = '⏹ CANCELLED';
      } else if (stateObj.latestLog) {
        const log = stateObj.latestLog;
        const st = String(log.status || '').toLowerCase();
        const isErr = st.includes('fail') || st.includes('error') || log.success === false;
        badgeEl.className = `wf-status-badge ${isErr ? 'failed' : 'completed'}`;
        const timeStr = log.completed_at || log.started_at || log.timestamp || '';
        const shortTime = timeStr ? ` • ${new Date(timeStr).toLocaleTimeString()}` : '';
        badgeEl.textContent = isErr ? `✖ FAILED${shortTime}` : `✔ COMPLETED${shortTime}`;
      } else if (stateObj.error) {
        badgeEl.className = 'wf-status-badge failed';
        badgeEl.textContent = '✖ ERROR';
      } else {
        badgeEl.className = 'wf-status-badge idle';
        badgeEl.textContent = 'IDLE';
      }
    }
  }

  function renderWorkflowLogsBox(wfId, ev) {
    const box = document.getElementById(`wf-logs-box-${wfId}`);
    if (!box) return;
    box.classList.remove('hidden');

    if (ev.error) {
      box.innerHTML = `<div style="color: #f87171;">✖ ${escapeHtml(ev.error)}</div>`;
      return;
    }

    const parts = [];
    if (ev.output && typeof ev.output === 'object' && Object.keys(ev.output).length > 0 && !ev.output.error) {
      const outText = ev.output.output || ev.output.result || ev.output.content || JSON.stringify(ev.output, null, 2);
      parts.push(`=== Latest Output ===\n${typeof outText === 'string' ? outText : JSON.stringify(outText, null, 2)}`);
    }
    if (ev.logs && typeof ev.logs === 'object') {
      const list = ev.logs.logs || ev.logs.executions || ev.logs.items || (Array.isArray(ev.logs) ? ev.logs : null);
      if (Array.isArray(list) && list.length > 0) {
        const formattedLogs = list.slice(0, 10).map((entry, idx) => {
          if (typeof entry === 'string') return entry;
          const ts = entry.timestamp || entry.started_at || entry.created_at || `#${idx + 1}`;
          const st = entry.status || (entry.success === false ? 'FAILED' : 'OK');
          const msg = entry.output || entry.result || entry.message || entry.logs || JSON.stringify(entry, null, 2);
          return `[${ts}] (${st})\n${typeof msg === 'string' ? msg : JSON.stringify(msg, null, 2)}`;
        }).join('\n----------------------------------------\n');
        parts.push(`=== Execution Logs (${list.length}) ===\n${formattedLogs}`);
      } else if (!ev.logs.error && Object.keys(ev.logs).length > 0) {
        parts.push(`=== Execution Logs ===\n${JSON.stringify(ev.logs, null, 2)}`);
      }
    }

    const combinedText = parts.length > 0 ? parts.join('\n\n') : 'No execution logs or output recorded yet for this workflow.';

    box.innerHTML = `
      <div class="wf-logs-header">
        <span>📋 Workflow Execution Logs & Output</span>
        <div style="display: flex; gap: 4px;">
          <button class="card-action-btn wf-logs-copy-btn">Copy</button>
          <button class="card-action-btn wf-logs-refresh-btn">🔄</button>
          <button class="card-action-btn wf-logs-close-btn">✕</button>
        </div>
      </div>
      <pre class="wf-logs-pre">${escapeHtml(combinedText)}</pre>
    `;

    const copyBtn = box.querySelector('.wf-logs-copy-btn');
    if (copyBtn) {
      copyBtn.addEventListener('click', () => window.copyToClipboard(combinedText, copyBtn));
    }
    const refBtn = box.querySelector('.wf-logs-refresh-btn');
    if (refBtn) {
      refBtn.addEventListener('click', () => {
        vscode.postMessage({ type: 'get_workflow_logs', id: wfId });
      });
    }
    const closeBtn = box.querySelector('.wf-logs-close-btn');
    if (closeBtn) {
      closeBtn.addEventListener('click', () => box.classList.add('hidden'));
    }
  }

  function renderWorkflowsList(workflows) {
    if (!workflowsListEl) return;

    if (!workflows || workflows.length === 0) {
      workflowsListEl.innerHTML = '<div class="empty-state">No remote workflows found on server or server offline.</div>';
      return;
    }

    workflowsListEl.innerHTML = '';
    workflows.forEach((w) => {
      const card = document.createElement('div');
      card.className = 'workflow-card';

      card.innerHTML = `
        <div class="workflow-header">
          <span class="workflow-name">⚡ ${escapeHtml(w.name)}</span>
          <div style="display: flex; align-items: center; gap: 6px;">
            <span id="wf-status-badge-${escapeHtml(w.id)}" class="wf-status-badge idle">IDLE</span>
            <span class="workflow-badge ${w.enabled ? 'enabled' : 'disabled'}">${w.enabled ? 'ENABLED' : 'DISABLED'}</span>
          </div>
        </div>
        <div class="card-details">
          <div class="card-row"><span class="card-label">ID:</span><span class="card-val">${escapeHtml(w.id)}</span></div>
          ${w.schedule ? `<div class="card-row"><span class="card-label">Schedule:</span><span class="card-val">${escapeHtml(JSON.stringify(w.schedule))}</span></div>` : ''}
          <div class="card-row"><span class="card-label">Agents:</span><span class="card-val">${w.agentsCount || 1}</span></div>
        </div>
        <div class="card-actions" style="flex-wrap: wrap;">
          <button id="wf-logs-btn-${escapeHtml(w.id)}" class="card-action-btn">📋 Fetch Logs</button>
          <button id="wf-status-btn-${escapeHtml(w.id)}" class="card-action-btn" title="Check Run Status">🔄 Status</button>
          <button id="wf-stop-btn-${escapeHtml(w.id)}" class="card-action-btn delete hidden">⏹ Stop</button>
          <button id="wf-run-btn-${escapeHtml(w.id)}" class="run-wf-btn" data-id="${escapeHtml(w.id)}" data-name="${escapeHtml(w.name)}">▶ Run Workflow</button>
        </div>
        <div id="wf-logs-box-${escapeHtml(w.id)}" class="wf-logs-box hidden"></div>
      `;

      card.querySelector(`#wf-run-btn-${w.id}`).addEventListener('click', () => {
        if (!workflowStateMap[w.id]) workflowStateMap[w.id] = {};
        workflowStateMap[w.id].running = true;
        workflowStateMap[w.id].triggeredByUser = true;
        updateWorkflowStatusUI(w.id, { running: true });
        vscode.postMessage({ type: 'run_workflow', id: w.id, name: w.name });
        startWorkflowPolling(w.id);
      });

      card.querySelector(`#wf-stop-btn-${w.id}`).addEventListener('click', () => {
        vscode.postMessage({ type: 'cancel_workflow', id: w.id });
      });

      card.querySelector(`#wf-status-btn-${w.id}`).addEventListener('click', () => {
        vscode.postMessage({ type: 'get_workflow_status', id: w.id });
      });

      card.querySelector(`#wf-logs-btn-${w.id}`).addEventListener('click', () => {
        const box = document.getElementById(`wf-logs-box-${w.id}`);
        if (box) {
          box.classList.remove('hidden');
          box.innerHTML = '<div style="color: #38bdf8;">🔄 Fetching workflow execution logs & output...</div>';
        }
        vscode.postMessage({ type: 'get_workflow_logs', id: w.id });
      });

      workflowsListEl.appendChild(card);

      // Query initial status from server
      vscode.postMessage({ type: 'get_workflow_status', id: w.id });
    });
  }

  // --- Handle messages from VS Code extension ---
  window.addEventListener('message', (event) => {
    const message = event.data;

    if (message.type === 'diff_applied') {
      const card = document.getElementById(`diff-card-${message.id}`);
      if (card) {
        card.classList.add('applied');
        card.querySelector('.diff-actions').innerHTML = '<span style="color: #34d399; font-weight: 500;">✔ Changes Applied</span>';
      }
      return;
    }

    if (message.type === 'clear') {
      messagesContainer.innerHTML = '';
      currentAssistantBubble = null;
      setActivity(false);
      return;
    }

    if (message.type === 'fetch_provider_models_result') {
      if (message.success && Array.isArray(message.models)) {
        llmModelDatalist.innerHTML = '';
        message.models.forEach((m) => {
          const opt = document.createElement('option');
          opt.value = m;
          llmModelDatalist.appendChild(opt);
        });
        llmModelsStatus.textContent = `\u2714 Loaded ${message.models.length} models. Type or select from dropdown list.`;
        llmModelsStatus.className = 'hint-status success';
        if (!llmInputModel.value && message.models.length > 0) {
          llmInputModel.value = message.models[0];
        }
      } else {
        llmModelsStatus.textContent = `\u2716 ${message.error || 'Failed to load models'}`;
        llmModelsStatus.className = 'hint-status error';
      }
      return;
    }

    if (message.type === 'test_llm_api_result') {
      if (message.success) {
        llmTestResult.textContent = `\u2714 ${message.message}`;
        llmTestResult.className = 'test-result-badge success';
      } else {
        llmTestResult.textContent = `\u2716 ${message.message}`;
        llmTestResult.className = 'test-result-badge error';
      }
      return;
    }

    if (message.type === 'llm_config_data') {
      renderLlmList(message);
      return;
    }

    if (message.type === 'mcp_config_data') {
      renderMcpList(message);
      return;
    }

    if (message.type === 'skills_data') {
      renderSkillsList(message);
      return;
    }

    if (message.type === 'skills_changed') {
      updateAttachedSkillsChips(message.activeSkills);
      return;
    }

    if (message.type === 'memory_archives_data') {
      renderMemoryArchives(message.archives);
      return;
    }

    if (message.type === 'server_config_data') {
      renderServerProfiles(message);
      return;
    }

    if (message.type === 'test_mcp_server_result') {
      if (message.fromModal && mcpModalToolsResult) {
        renderMcpToolsResultBox(mcpModalToolsResult, message);
      }
      if (message.serverName) {
        const safeId = message.serverName.replace(/[^a-zA-Z0-9_-]/g, '_');
        const cardBox = document.getElementById(`mcp-card-tools-${safeId}`);
        if (cardBox) {
          renderMcpToolsResultBox(cardBox, message);
        }
      }
      return;
    }

    if (message.type === 'test_server_connection_result') {
      if (message.fromModal && serverModalTestResult) {
        serverModalTestResult.textContent = `${message.success ? '✔' : '✖'} ${message.message}`;
        serverModalTestResult.className = `test-result-badge ${message.success ? 'success' : 'error'}`;
      }
      if (message.profileName) {
        const safeId = message.profileName.replace(/[^a-zA-Z0-9_-]/g, '_');
        const statusEl = document.getElementById(`srv-test-status-${safeId}`);
        if (statusEl) {
          statusEl.className = `server-card-status ${message.success ? 'success' : 'error'}`;
          statusEl.textContent = `${message.success ? '✔' : '✖'} ${message.message}`;
        }
      }
      return;
    }

    if (message.type === 'cli_config_data') {
      populateCliSettingsForm(message);
      return;
    }

    if (message.type !== 'agent_event') return;
    const ev = message.event;

    switch (ev.event) {
      case 'ready':
      case 'status':
        statusBadge.textContent = 'Ready';
        statusBadge.className = 'badge ready';
        if (ev.toolsCount !== undefined && toolsBadge) {
          toolsBadge.textContent = `${ev.toolsCount} tools`;
        }
        if (typeof ev.ragConfigured === 'boolean') updateRagModeOption(ev.ragConfigured);
        if (ev.mode) modeSelect.value = ev.mode;
        if (ev.model && modelSelect.value !== ev.model) {
          activeSelectedProfile = ev.model;
          if (Array.from(modelSelect.options).some(o => o.value === ev.model)) modelSelect.value = ev.model;
        }
        if (ev.resolvedLlmFile) {
          activeLlmFilePath = ev.resolvedLlmFile;
          llmFilePathEl.textContent = activeLlmFilePath;
          llmFilePathEl.title = activeLlmFilePath;
        }
        if (ev.activeSkills) {
          updateAttachedSkillsChips(ev.activeSkills);
        }
        if (Array.isArray(ev.history) && ev.history.length > 0) {
          renderRestoredSessionMessages(ev.history, !!ev.isTurnActive, false);
        } else if (ev.isTurnActive && !isGenerating) {
          setActivity(true, 'Agent is processing...');
        }
        break;

      case 'session_loaded': {
        const force = explicitSessionLoadRequested;
        explicitSessionLoadRequested = false;
        renderRestoredSessionMessages(ev.messages || [], !!ev.isTurnActive, force);
        vscode.postMessage({ type: 'list_sessions' });
        break;
      }

      case 'sessions_list': {
        renderSavedSessionsList(ev.sessions || [], ev.activeSessionId);
        break;
      }

      case 'session_saved': {
        vscode.postMessage({ type: 'list_sessions' });
        break;
      }

      case 'models':
        if (ev.models && Array.isArray(ev.models)) {
          modelSelect.innerHTML = '';
          ev.models.forEach((m) => {
            const opt = document.createElement('option');
            opt.value = m.name;
            const badge = m.ctxAndPricing ? ` [${m.ctxAndPricing}]` : '';
            opt.textContent = `${m.name} (${m.model || m.provider}${badge})`;
            if ((activeSelectedProfile && m.name === activeSelectedProfile) || (!activeSelectedProfile && m.isDefault)) opt.selected = true;
            modelSelect.appendChild(opt);
          });
        }
        break;

      


      case 'skills_changed':
        if (ev.activeSkills) {
          updateAttachedSkillsChips(ev.activeSkills);
        }
        break;

      case 'context_compressed': {
        const bubble = getOrCreateAssistantBubble();
        bubble.innerHTML += `<div style="font-size: 11px; color: #a5b4fc; margin: 4px 0;">⚡ [Context Compressed] ${ev.originalTokens} → ${ev.compressedTokens} tokens (${ev.compressedTurnCount} turns archived into Episodic Memory)</div>`;
        scrollToBottom();
        break;
      }

      case 'memory_retrieved': {
        const bubble = getOrCreateAssistantBubble();
        bubble.innerHTML += `<div style="font-size: 11px; color: #c084fc; margin: 4px 0;">🧠 [Episodic Memory] Recalled ${ev.recalledTurnCount} historical turns (Archive: ${escapeHtml(ev.archiveId || '')})</div>`;
        scrollToBottom();
        break;
      }

      case 'memory_archived': {
        vscode.postMessage({ type: 'get_memory_archives' });
        break;
      }

      case 'workflows':
        renderWorkflowsList(ev.workflows);
        break;

      case 'workflow_run_started': {
        if (ev.workflowId) {
          if (!workflowStateMap[ev.workflowId]) workflowStateMap[ev.workflowId] = {};
          workflowStateMap[ev.workflowId].running = true;
          workflowStateMap[ev.workflowId].runId = ev.runId;
          updateWorkflowStatusUI(ev.workflowId, { running: true, runId: ev.runId });
          startWorkflowPolling(ev.workflowId);
        }
        break;
      }

      case 'workflow_status': {
        if (ev.workflowId) {
          const wfId = ev.workflowId;
          const prev = workflowStateMap[wfId] || {};
          const wasRunning = !!prev.running;
          prev.running = !!ev.running;
          updateWorkflowStatusUI(wfId, ev);
          if (!ev.running) {
            stopWorkflowPolling(wfId);
            if (wasRunning && prev.triggeredByUser) {
              prev.triggeredByUser = false;
              vscode.postMessage({ type: 'get_workflow_logs', id: wfId });
            }
          }
        }
        break;
      }

      case 'workflow_logs': {
        if (ev.workflowId) {
          renderWorkflowLogsBox(ev.workflowId, ev);
        }
        break;
      }

      case 'mode_changed':
        if (typeof ev.ragConfigured === 'boolean') updateRagModeOption(ev.ragConfigured);
        modeSelect.value = ev.mode;
        break;
      case 'config_reloaded':
        if (typeof ev.ragConfigured === 'boolean') updateRagModeOption(ev.ragConfigured);
        if (ev.mode) modeSelect.value = ev.mode;
        break;
      case 'permissions_updated':
        if (cfgPermRead && typeof ev.autoApproveRead === 'boolean') cfgPermRead.checked = ev.autoApproveRead;
        if (cfgPermWrite && typeof ev.autoApproveWrite === 'boolean') cfgPermWrite.checked = ev.autoApproveWrite;
        if (cfgPermExecute && typeof ev.autoApproveExecute === 'boolean') cfgPermExecute.checked = ev.autoApproveExecute;
        if (cfgPermNetwork && typeof ev.autoApproveNetwork === 'boolean') cfgPermNetwork.checked = ev.autoApproveNetwork;
        break;

      case 'model_changed':
        const targetProfile = ev.profile || ev.model;
        if (targetProfile) {
          activeSelectedProfile = targetProfile;
          if (Array.from(modelSelect.options).some(o => o.value === targetProfile)) {
            modelSelect.value = targetProfile;
          }
        }
        break;

      case 'log':
        if (ev.message && isGenerating) {
          baseActivityText = String(ev.message).split(/\r?\n/)[0].slice(0, 120);
          activityText.innerText = baseActivityText;
        }
        break;

      case 'start':
        setActivity(true, 'Agent thinking...');
        currentAssistantBubble = null;
        break;

      case 'chunk':
        const bubble = getOrCreateAssistantBubble();
        bubble.innerHTML += formatSimpleMarkdown(ev.text || '');
        scrollToBottom();
        break;

      case 'tool_result':
        renderToolCard(ev);
        currentAssistantBubble = null;
        break;

      case 'diff':
        renderDiffCard(ev);
        break;

      case 'subagent_start':
        renderSubAgentCard(ev);
        setActivity(true, `Sub-agent ${ev.subagent} executing...`);
        break;

      case 'subagent_done':
        setActivity(true, 'Synthesizing sub-agent results...');
        break;

      case 'permission_request':
        renderPermissionCard(ev);
        break;

      case 'error': {
        setActivity(false);
        const errBubble = getOrCreateAssistantBubble();
        const msg = ev.message || 'Unknown error occurred.';
        const isAuthError = msg.includes('AuthenticationException') || msg.includes('API key') || msg.includes('401') || msg.includes('Unauthorized');
        
        let errorHtml = `
          <div class="error-card">
            <div><strong>⚠️ Agent Error:</strong> ${escapeHtml(msg)}</div>
            ${isAuthError ? `<button class="error-action-btn" onclick="window.switchTab('llms')">⚙ Open LLM Settings to configure API Key</button>` : ''}
          </div>
        `;
        errBubble.innerHTML += errorHtml;
        scrollToBottom();
        break;
      }

      case 'cancelled':
        setActivity(false);
        currentAssistantBubble = null;
        break;

      case 'session_cleared':
        messagesContainer.innerHTML = '';
        currentAssistantBubble = null;
        setActivity(false);
        break;

      case 'done':
        setActivity(false);
        if (ev.response && (!currentAssistantBubble || !currentAssistantBubble.innerText.trim())) {
          const bubble = getOrCreateAssistantBubble();
          bubble.innerHTML = formatSimpleMarkdown(ev.response);
        }
        currentAssistantBubble = null;
        scrollToBottom();
        break;
    }
  });

  function renderToolCard(ev) {
    const card = document.createElement('details');
    card.className = 'tool-card';
    const outputStr = typeof ev.output === 'object' ? JSON.stringify(ev.output, null, 2) : String(ev.output || '(no output)');
    card.innerHTML = `
      <summary class="tool-summary">
        <span>🔧</span>
        <span class="tool-name">${escapeHtml(ev.tool || 'tool')}</span>
        <span class="tool-duration">completed</span>
      </summary>
      <div class="tool-details-box">
        <div style="display: flex; justify-content: flex-end; padding: 4px 6px;">
          <button class="msg-copy-btn tool-copy-btn" title="Copy output">
            ${COPY_SVG}<span>Copy Output</span>
          </button>
        </div>
        <div class="tool-details">${escapeHtml(outputStr)}</div>
      </div>
    `;
    const copyBtn = card.querySelector('.tool-copy-btn');
    if (copyBtn) {
      copyBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        window.copyToClipboard(outputStr, copyBtn);
      });
    }
    messagesContainer.appendChild(card);
    scrollToBottom();
  }

  function renderDiffCard(ev) {
    diffCounter++;
    const cardId = `diff-${diffCounter}`;
    const card = document.createElement('div');
    card.className = 'diff-card';
    card.id = `diff-card-${cardId}`;

    const fileName = ev.path ? ev.path.split(/[\\/]/).pop() : 'modified_file';
    card.innerHTML = `
      <div class="diff-header">
        <span class="diff-title">🔀 ${escapeHtml(fileName)}</span>
      </div>
      <div style="font-size: 11px; color: var(--vscode-descriptionForeground);">
        Proposed changes for: <code>${escapeHtml(ev.path || '')}</code>
      </div>
      <div class="diff-actions">
        <button class="btn-review" id="review-${cardId}">Review Diff</button>
        <button class="btn-apply" id="apply-${cardId}">Accept & Apply</button>
        <button class="btn-reject" id="reject-${cardId}">Dismiss</button>
      </div>
    `;
    messagesContainer.appendChild(card);
    scrollToBottom();

    document.getElementById(`review-${cardId}`).addEventListener('click', () => {
      vscode.postMessage({
        type: 'review_diff',
        path: ev.path,
        original: ev.original,
        modified: ev.modified,
      });
    });

    document.getElementById(`apply-${cardId}`).addEventListener('click', () => {
      vscode.postMessage({
        type: 'apply_diff',
        path: ev.path,
        modified: ev.modified,
        id: cardId,
      });
    });

    document.getElementById(`reject-${cardId}`).addEventListener('click', () => {
      card.remove();
    });
  }

  function renderSubAgentCard(ev) {
    const card = document.createElement('div');
    card.className = 'subagent-card';
    card.innerHTML = `
      <span class="subagent-badge">Sub-Agent</span>
      <span class="subagent-title"><strong>${escapeHtml(ev.subagent)}</strong>: ${escapeHtml(ev.task || 'Delegated task')}</span>
    `;
    messagesContainer.appendChild(card);
    scrollToBottom();
  }

  function renderPermissionCard(req) {
    const card = document.createElement('div');
    card.className = 'approval-card';
    const reqId = req.requestId || req.id;
    const toolName = req.tool || req.toolName || 'tool';
    const paramsStr = typeof req.parameters === 'object' ? JSON.stringify(req.parameters, null, 2) : String(req.parameters || '{}');
    card.innerHTML = `
      <div class="approval-header">
        <span class="approval-icon">⚠️</span>
        <span class="approval-title">Tool Approval Required</span>
        <span class="approval-risk risk-${escapeHtml(req.risk || 'execute')}">${escapeHtml(req.risk || 'execute')}</span>
      </div>
      <div class="approval-body">
        <div class="approval-row"><strong>Tool:</strong> <code>${escapeHtml(toolName)}</code></div>
        <div class="approval-row"><strong>Parameters:</strong></div>
        <pre class="approval-params">${escapeHtml(paramsStr)}</pre>
      </div>
      <div class="approval-actions">
        <button class="btn-approve" id="approve-${reqId}">✓ Approve</button>
        <button class="btn-always" id="always-${reqId}">⚡ Always Allow</button>
        <button class="btn-reject" id="reject-${reqId}">✕ Reject</button>
      </div>
    `;
    messagesContainer.appendChild(card);
    currentAssistantBubble = null;
    scrollToBottom();

    const approveBtn = document.getElementById(`approve-${reqId}`);
    if (approveBtn) {
      approveBtn.addEventListener('click', () => {
        vscode.postMessage({ type: 'permission_response', id: reqId, approved: true });
        card.remove();
      });
    }

    const alwaysBtn = document.getElementById(`always-${reqId}`);
    if (alwaysBtn) {
      alwaysBtn.addEventListener('click', () => {
        vscode.postMessage({ type: 'permission_response', id: reqId, approved: true, always: true, tool: toolName, risk: req.risk || 'execute' });
        card.remove();
        document.querySelectorAll('.approval-card').forEach((otherCard) => {
          const otherApprove = otherCard.querySelector('.btn-approve');
          if (otherApprove) otherApprove.click();
        });
        card.remove();
      });
    }

    const rejectBtn = document.getElementById(`reject-${reqId}`);
    if (rejectBtn) {
      rejectBtn.addEventListener('click', () => {
        vscode.postMessage({ type: 'permission_response', id: reqId, approved: false });
        card.remove();
      });
    }
  }
})();
