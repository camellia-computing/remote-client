import 'package:flutter/material.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/models/chat_model.dart';
import 'package:camellia_remote_app/models/chat_types.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';

import '../../mobile/pages/home_page.dart';

enum ChatPageType {
  mobileMain,
  desktopCM,
}

class ChatPage extends StatelessWidget implements PageShape {
  late final ChatModel chatModel;
  final ChatPageType? type;

  ChatPage({ChatModel? chatModel, this.type}) {
    this.chatModel = chatModel ?? gFFI.chatModel;
  }

  @override
  final title = translate("Chat");

  @override
  final icon = unreadTopRightBuilder(gFFI.chatModel.mobileUnreadSum);

  @override
  final appBarActions = [
    PopupMenuButton<MessageKey>(
        tooltip: "",
        icon: unreadTopRightBuilder(gFFI.chatModel.mobileUnreadSum,
            icon: Icon(Icons.group)),
        itemBuilder: (context) {
          // only mobile need [appBarActions], just bind gFFI.chatModel
          final chatModel = gFFI.chatModel;
          return chatModel.messages.entries.map((entry) {
            final key = entry.key;
            final user = entry.value.chatUser;
            final client = gFFI.serverModel.clients
                .firstWhereOrNull((e) => e.id == key.connId);
            final connected =
                gFFI.serverModel.clients.any((e) => e.id == key.connId);
            return PopupMenuItem<MessageKey>(
              child: Row(
                children: [
                  Icon(
                          key.isOut
                              ? Icons.call_made_rounded
                              : Icons.call_received_rounded,
                          color: MyTheme.accent)
                      .marginOnly(right: 6),
                  Text("${user.firstName}   ${user.id}"),
                  if (connected)
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Color.fromARGB(255, 46, 205, 139)),
                    ).marginSymmetric(horizontal: 2),
                  if (client != null)
                    unreadMessageCountBuilder(client.unreadChatMessageCount)
                        .marginOnly(left: 4)
                ],
              ),
              value: key,
            );
          }).toList();
        },
        onSelected: (key) {
          gFFI.chatModel.changeCurrentKey(key);
        })
  ];

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: chatModel,
      child: Container(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Consumer<ChatModel>(
          builder: (context, chatModel, child) {
            final readOnly = type == ChatPageType.mobileMain &&
                    (chatModel.currentKey.connId == ChatModel.clientModeID ||
                        gFFI.serverModel.clients.every((e) =>
                            e.id != chatModel.currentKey.connId ||
                            chatModel.currentUser == null)) ||
                type == ChatPageType.desktopCM &&
                    gFFI.serverModel.clients
                            .firstWhereOrNull(
                                (e) => e.id == chatModel.currentKey.connId)
                            ?.disconnected ==
                        true;
            return LayoutBuilder(builder: (context, constraints) {
              final messages =
                  chatModel.messages[chatModel.currentKey]?.chatMessages ?? [];
              final chat = Column(
                children: [
                  Expanded(
                    child: messages.isEmpty
                        ? const SizedBox.shrink()
                        : ListView.builder(
                            reverse: true,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 10),
                            itemCount: messages.length,
                            itemBuilder: (context, index) {
                              return _ChatMessageBubble(
                                message: messages[index],
                                isOwnMessage:
                                    messages[index].user.id == chatModel.me.id,
                                maxWidth: constraints.maxWidth * 0.7,
                              );
                            },
                          ),
                  ),
                  if (!readOnly) _ChatInput(chatModel: chatModel),
                ],
              ).workaroundFreezeLinuxMint();
              return SelectionArea(child: chat);
            }).paddingOnly(bottom: 8);
          },
        ),
      ),
    );
  }
}

class _ChatInput extends StatelessWidget {
  final ChatModel chatModel;

  const _ChatInput({required this.chatModel});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
      child: TextField(
        controller: chatModel.textController,
        focusNode: chatModel.inputNode,
        minLines: 1,
        maxLines: 4,
        style: TextStyle(
          fontSize: 14,
          color: Theme.of(context).textTheme.titleLarge?.color,
        ),
        decoration: InputDecoration(
          isDense: true,
          hintText: translate('Write a message'),
          filled: true,
          fillColor: Theme.of(context).colorScheme.surface,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10.0),
            borderSide: const BorderSide(width: 1, style: BorderStyle.solid),
          ),
          suffixIcon: IconButton(
            icon: Icon(Icons.send_rounded, color: MyTheme.accent),
            tooltip: translate('Send'),
            onPressed: () => chatModel.sendText(chatModel.textController.text),
          ),
        ),
      ),
    );
  }
}

class _ChatMessageBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isOwnMessage;
  final double maxWidth;

  const _ChatMessageBubble({
    required this.message,
    required this.isOwnMessage,
    required this.maxWidth,
  });

  @override
  Widget build(BuildContext context) {
    final color = isOwnMessage ? MyTheme.accent : Colors.blueGrey;
    return Align(
      alignment: isOwnMessage ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(8),
              topRight: const Radius.circular(8),
              bottomRight: Radius.circular(isOwnMessage ? 2 : 8),
              bottomLeft: Radius.circular(isOwnMessage ? 8 : 2),
            ),
          ),
          child: Column(
            crossAxisAlignment:
                isOwnMessage ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              Text(message.text, style: const TextStyle(color: Colors.white)),
              Text(
                "${message.createdAt.hour}:${message.createdAt.minute.toString().padLeft(2, '0')}",
                style: const TextStyle(color: Colors.white, fontSize: 8),
              ).marginOnly(top: 3),
            ],
          ),
        ),
      ),
    );
  }
}
