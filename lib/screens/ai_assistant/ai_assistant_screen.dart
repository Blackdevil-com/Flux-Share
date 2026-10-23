import 'package:flutter/material.dart';
import '../../ai/ai_config.dart';
import '../../ai/ai_models.dart';
import '../../ai/ai_service.dart';
import '../../app/theme.dart';
import '../settings/settings_screen.dart';

/// Interactive AI Assistant screen for querying transfer diagnostics, history,
/// network performance, and storage metrics without hallucinations.
class AIAssistantScreen extends StatefulWidget {
  const AIAssistantScreen({super.key});

  @override
  State<AIAssistantScreen> createState() => _AIAssistantScreenState();
}

class _AIAssistantScreenState extends State<AIAssistantScreen> {
  final AIService _aiService = AIService();
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isProcessing = false;

  final List<String> _quickPrompts = [
    'Why is my transfer slow?',
    'How many files did I receive today?',
    'Which transfer failed?',
    'Show me the largest files I received',
    'How can I improve transfer speed?',
    'Show storage statistics',
  ];

  @override
  void initState() {
    super.initState();
    // Add welcome message if history is empty
    if (_aiService.assistantHistory.isEmpty) {
      _addWelcomeMessage();
    }
  }

  void _addWelcomeMessage() {
    // Welcome message rendered dynamically
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _submitQuestion(String query) async {
    final text = query.trim();
    if (text.isEmpty || _isProcessing) return;

    _textController.clear();
    setState(() {
      _isProcessing = true;
    });

    _scrollToBottom();

    await _aiService.askAssistant(text);

    if (mounted) {
      setState(() {
        _isProcessing = false;
      });
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final config = _aiService.config;
    final messages = _aiService.assistantHistory;

    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      appBar: AppBar(
        title: const Text('AI Assistant'),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune_rounded),
            tooltip: 'AI Settings',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Status and privacy header
            _buildStatusHeader(config),

            // Messages chat area
            Expanded(
              child: messages.isEmpty
                  ? _buildEmptyState()
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(AppSpacing.s16),
                      itemCount: messages.length,
                      itemBuilder: (context, index) {
                        final msg = messages[index];
                        return _buildMessageBubble(msg);
                      },
                    ),
            ),

            if (_isProcessing)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s16, vertical: AppSpacing.s8),
                alignment: Alignment.centerLeft,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.primaryBlack,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.s8),
                    Text(
                      'Analyzing application metrics...',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.mediumGray,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                ),
              ),

            // Quick Prompt Chips
            _buildQuickPromptList(),

            // Chat input field
            _buildInputField(),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusHeader(AIConfig config) {
    final bool enabled = config.isAiEnabled;
    final String statusLabel = !enabled
        ? 'Disabled'
        : config.isUsingCloud
            ? 'Gemini Cloud'
            : 'Local Rule-Based (Private)';
    final Color dotColor = !enabled ? AppColors.mediumGray : Colors.green;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s16, vertical: AppSpacing.s10),
      decoration: const BoxDecoration(
        color: AppColors.lightGray,
        border: Border(
          bottom: BorderSide(color: AppColors.borderGray, width: 1.0),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: dotColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: AppSpacing.s8),
          Text(
            'AI Status: $statusLabel',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.primaryBlack,
            ),
          ),
          const Spacer(),
          const Icon(
            Icons.shield_outlined,
            size: 14,
            color: AppColors.mediumGray,
          ),
          const SizedBox(width: 4),
          const Text(
            '100% Deterministic Tools',
            style: TextStyle(
              fontSize: 11,
              color: AppColors.mediumGray,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.s24),
      child: Column(
        children: [
          const SizedBox(height: AppSpacing.s32),
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: AppColors.lightGray,
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.borderGray),
            ),
            child: const Icon(
              Icons.auto_awesome_rounded,
              color: AppColors.primaryBlack,
              size: 32,
            ),
          ),
          const SizedBox(height: AppSpacing.s16),
          const Text(
            'FLUXSHARE Assistant',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: AppColors.primaryBlack,
            ),
          ),
          const SizedBox(height: AppSpacing.s8),
          const Text(
            'Ask anything about your transfer speeds, connection stability, received files, or storage. '
            'The AI queries verified live application tools and never invents fake data.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: AppColors.mediumGray,
              height: 1.4,
            ),
          ),
          const SizedBox(height: AppSpacing.s24),
          const Text(
            'Try asking:',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: AppColors.darkGray,
            ),
          ),
          const SizedBox(height: AppSpacing.s12),
          Wrap(
            spacing: AppSpacing.s8,
            runSpacing: AppSpacing.s8,
            alignment: WrapAlignment.center,
            children: _quickPrompts.take(4).map((p) => ActionChip(
              backgroundColor: AppColors.backgroundWhite,
              side: const BorderSide(color: AppColors.borderGray),
              label: Text(
                p,
                style: const TextStyle(fontSize: 12, color: AppColors.primaryBlack),
              ),
              onPressed: () => _submitQuestion(p),
            )).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(AIAssistantMessage message) {
    final isUser = message.role == 'user';

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!isUser) ...[
            Container(
              width: 32,
              height: 32,
              margin: const EdgeInsets.only(right: AppSpacing.s8, top: 2),
              decoration: const BoxDecoration(
                color: AppColors.primaryBlack,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.auto_awesome_rounded,
                color: AppColors.backgroundWhite,
                size: 16,
              ),
            ),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                // Bubble Container
                Container(
                  padding: const EdgeInsets.all(AppSpacing.s14),
                  decoration: BoxDecoration(
                    color: isUser ? AppColors.primaryBlack : AppColors.lightGray,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(16),
                      topRight: const Radius.circular(16),
                      bottomLeft: Radius.circular(isUser ? 16 : 4),
                      bottomRight: Radius.circular(isUser ? 4 : 16),
                    ),
                    border: Border.all(
                      color: isUser ? AppColors.primaryBlack : AppColors.borderGray,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Tool Execution Badges
                      if (!isUser && message.toolBadges.isNotEmpty) ...[
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: message.toolBadges.map((tool) {
                            return Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: AppColors.backgroundWhite,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(color: AppColors.borderGray),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.bolt, size: 11, color: AppColors.mediumGray),
                                  const SizedBox(width: 2),
                                  Text(
                                    tool,
                                    style: const TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      color: AppColors.darkGray,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }).toList(),
                        ),
                        const SizedBox(height: AppSpacing.s8),
                      ],
                      Text(
                        message.content,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.45,
                          color: isUser ? AppColors.backgroundWhite : AppColors.primaryBlack,
                        ),
                      ),
                    ],
                  ),
                ),

                // Suggested Follow-up Questions
                if (!isUser && message.suggestedQuestions.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.s8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: message.suggestedQuestions.map((q) {
                      return InkWell(
                        onTap: () => _submitQuestion(q),
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppColors.backgroundWhite,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: AppColors.borderGray),
                          ),
                          child: Text(
                            q,
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppColors.primaryBlack,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ],
            ),
          ),
          if (isUser) ...[
            Container(
              width: 32,
              height: 32,
              margin: const EdgeInsets.only(left: AppSpacing.s8, top: 2),
              decoration: const BoxDecoration(
                color: AppColors.borderGray,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.person_rounded,
                color: AppColors.primaryBlack,
                size: 18,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildQuickPromptList() {
    return Container(
      height: 38,
      margin: const EdgeInsets.only(bottom: AppSpacing.s8),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s16),
        itemCount: _quickPrompts.length,
        separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.s8),
        itemBuilder: (context, index) {
          final p = _quickPrompts[index];
          return ActionChip(
            backgroundColor: AppColors.lightGray,
            side: const BorderSide(color: AppColors.borderGray),
            label: Text(
              p,
              style: const TextStyle(fontSize: 11, color: AppColors.primaryBlack),
            ),
            onPressed: () => _submitQuestion(p),
          );
        },
      ),
    );
  }

  Widget _buildInputField() {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s12),
      decoration: const BoxDecoration(
        color: AppColors.backgroundWhite,
        border: Border(
          top: BorderSide(color: AppColors.borderGray, width: 1.0),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _textController,
              textInputAction: TextInputAction.send,
              onSubmitted: _submitQuestion,
              decoration: InputDecoration(
                hintText: 'Ask FLUXSHARE anything...',
                hintStyle: const TextStyle(fontSize: 13, color: AppColors.mediumGray),
                filled: true,
                fillColor: AppColors.lightGray,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.s16,
                  vertical: AppSpacing.s10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: const BorderSide(color: AppColors.borderGray),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: const BorderSide(color: AppColors.borderGray),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: const BorderSide(color: AppColors.primaryBlack),
                ),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.s8),
          IconButton(
            icon: const Icon(Icons.arrow_upward_rounded),
            style: IconButton.styleFrom(
              backgroundColor: AppColors.primaryBlack,
              foregroundColor: AppColors.backgroundWhite,
            ),
            onPressed: () => _submitQuestion(_textController.text),
          ),
        ],
      ),
    );
  }
}
