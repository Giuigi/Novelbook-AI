class Message {
  final String id;
  final String role;  // 'user' or 'assistant'
  final String content;
  final DateTime timestamp;

  Message({required this.id, required this.role, required this.content})
      : timestamp = DateTime.now();

  Map<String, dynamic> toJson() => {
    'id': id,
    'role': role,
    'content': content,
    'timestamp': timestamp.toIso8601String(),
  };

  factory Message.fromJson(Map<String, dynamic> json) => Message(
    id: json['id'],
    role: json['role'],
    content: json['content'],
  );
}