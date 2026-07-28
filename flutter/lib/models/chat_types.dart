class ChatUser {
  String id;
  String? firstName;

  ChatUser({required this.id, this.firstName});
}

class ChatMessage {
  String text;
  ChatUser user;
  DateTime createdAt;

  ChatMessage({
    required this.text,
    required this.user,
    required this.createdAt,
  });
}
