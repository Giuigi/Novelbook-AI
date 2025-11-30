import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:uuid/uuid.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image_gallery_saver_plus/image_gallery_saver_plus.dart';
import 'package:localstorage/localstorage.dart';
import 'package:universal_html/html.dart' as html;
import 'package:flutter/foundation.dart'; // ← kIsWeb
import 'models/message.dart';
import 'dart:async';


void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MobileAds.instance.initialize();
  runApp(const NovelbookAI());
}

class NovelbookAI extends StatefulWidget {
  const NovelbookAI({super.key});
  @override
  State<NovelbookAI> createState() => _NovelbookAIState();
}

class _NovelbookAIState extends State<NovelbookAI> {
  final LocalStorage storage = LocalStorage('novelbook_ai.json');
  final TextEditingController _controller = TextEditingController();
  final List<Message> _messages = [];
  bool _isLoading = false;
  bool _isPremium = false;
  static const HF_API_KEY = String.fromEnvironment('HF_API_KEY');

  // Image Settings
  String _imageStyle = 'realistic';
  String _textStyle = 'dnd';
  bool _allowNsfw = false;
  bool _firstPerson = false;
  bool _autoSaveToGallery = true;

  late BannerAd _bannerAd;
  bool _isAdLoaded = false;
  RewardedAd? _rewardedAd;
  int _numRewardedLoadAttempts = 0;
  static const int maxFailedLoadAttempts = 3;
  static const String rewardedAdUnitId = 'ca-app-pub-3940256099942544/5224354917';  // Test ID; replace with yours

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _initBannerAd();
    _createRewardedAd();
  }

  void _initBannerAd() {
    _bannerAd = BannerAd(
      adUnitId: "ca-app-pub-3940256099942544/6300978111",
      size: AdSize.banner,
      request: const AdRequest(),
      listener: BannerAdListener(onAdLoaded: (_) => setState(() => _isAdLoaded = true)),
    )..load();
  }

  void _createRewardedAd() {
    RewardedAd.load(
      adUnitId: rewardedAdUnitId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (RewardedAd ad) {
          print('RewardedAd loaded successfully.');
          _rewardedAd = ad;
          _numRewardedLoadAttempts = 0;
        },
        onAdFailedToLoad: (LoadAdError error) {
          print('RewardedAd failed to load: $error');
          _rewardedAd = null;
          _numRewardedLoadAttempts++;
          if (_numRewardedLoadAttempts < maxFailedLoadAttempts) {
            Future.delayed(const Duration(seconds: 2), _createRewardedAd);  // Retry after delay
          }
        },
      ),
    );
  }

  void _showRewardedAd(String prompt) {
    if (_rewardedAd == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ad not ready – try again in a few seconds')),
      );
      return;
    }

    _rewardedAd!.fullScreenContentCallback = FullScreenContentCallback(
      onAdShowedFullScreenContent: (ad) => print('Ad showed'),
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        _rewardedAd = null;
        _createRewardedAd();
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        ad.dispose();
        _rewardedAd = null;
        _createRewardedAd();
      },
    );

    _rewardedAd!.show(
      onUserEarnedReward: (ad, reward) async {
        await _actuallyGenerateImage(prompt);
      },
    );
  }

  @override
  void dispose() {
    _rewardedAd?.dispose();
    super.dispose();
  }

  // ─────────────────────── STORAGE (Mobile + Web) ───────────────────────
  Future<void> _loadSettings() async {
    if (kIsWeb) {
      await storage.ready;
      setState(() {
        _isPremium = storage.getItem('premium') ?? false;
        _imageStyle = storage.getItem('image_style') ?? 'realistic';
        _allowNsfw = storage.getItem('allow_nsfw') ?? false;
        _firstPerson = storage.getItem('first_person') ?? false;
        _autoSaveToGallery = storage.getItem('auto_save') ?? true;

        final saved = storage.getItem('history');
        if (saved != null) {
          final List list = jsonDecode(saved);
          _messages.addAll(list.map((e) => Message.fromJson(e)));
        }
      });
    } else {
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        _isPremium = prefs.getBool('premium') ?? false;
        _imageStyle = prefs.getString('image_style') ?? 'realistic';
        _allowNsfw = prefs.getBool('allow_nsfw') ?? false;
        _firstPerson = prefs.getBool('first_person') ?? false;
        _autoSaveToGallery = prefs.getBool('auto_save') ?? true;

        final saved = prefs.getStringList('history') ?? [];
        _messages.addAll(saved.map((e) => Message.fromJson(jsonDecode(e))));
      });
    }
  }

  Future<void> _saveSettings() async {
    if (kIsWeb) {
      await storage.ready;
      storage.setItem('premium', _isPremium);
      storage.setItem('image_style', _imageStyle);
      storage.setItem('allow_nsfw', _allowNsfw);
      storage.setItem('first_person', _firstPerson);
      storage.setItem('auto_save', _autoSaveToGallery);
      storage.setItem('history', jsonEncode(_messages.map((m) => m.toJson()).toList()));
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('premium', _isPremium);
      await prefs.setString('image_style', _imageStyle);
      await prefs.setBool('allow_nsfw', _allowNsfw);
      await prefs.setBool('first_person', _firstPerson);
      await prefs.setBool('auto_save', _autoSaveToGallery);
      await prefs.setStringList('history',
          _messages.map((m) => jsonEncode(m.toJson())).toList());
    }
  }

  // ─────────────────────── TEXT GENERATION (Free & Unlimited) ───────────────────────
  Future<void> _sendMessage() async {
    if (_controller.text.trim().isEmpty || _isLoading) return;

    final userText = _controller.text.trim();
    setState(() {
      _messages.add(Message(id: const Uuid().v4(), role: 'user', content: userText));
      _isLoading = true;
    });
    _controller.clear();

    final String genrePrompt = _textStyle == 'dnd'
        ? "You are an expert D&D dungeon master. Keep replies very short (2–4 sentences). Always end with 3 numbered choices.\nExample: You see a dragon. 1. Fight 2. Run 3. Talk"
        : "You are a masterful dark-fantasy novelist. Write rich, immersive prose. Max 140 words per reply. End with a hook or cliffhanger.";

    final String viewPrompt = _firstPerson ? "Write in first-person (I see, I feel)." : "Write in third-person limited.";
    final String nsfwPrompt = _allowNsfw ? "Mature/sensual themes allowed when appropriate." : "Keep everything SFW – no sexual content.";

    final String systemPrompt = "$genrePrompt $viewPrompt $nsfwPrompt Never speak or act for the player.";

    try {
      final response = await http.post(
        Uri.parse("https://router.huggingface.co/hf/inference/v1/chat/completions"),
        headers: {
          "Authorization": "Bearer $HF_API_KEY",
          "Content-Type": "application/json",
        },
        body: jsonEncode({
          "model": "mistralai/Mistral-7B-Instruct-v0.3",
          "messages": [
            {"role": "system", "content": systemPrompt},
            ..._messages.map((m) => {"role": m.role == 'user' ? "user" : "assistant", "content": m.content}),
            {"role": "user", "content": userText}
          ],
          "max_tokens": 300,
          "temperature": 0.85,
          "stream": false
        }),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final aiText = data['choices'][0]['message']['content'].toString().trim();

        setState(() {
          _messages.add(Message(id: const Uuid().v4(), role: 'assistant', content: aiText));
        });
      } else {
        final error = jsonDecode(response.body)['error'] ?? response.reasonPhrase;
        _addError("AI error: $error");
      }
    } on TimeoutException {
      _addError("No signal from the ether… check your internet.");
    } catch (e) {
      _addError("The spirits are distracted… try again.");
    } finally {
      setState(() => _isLoading = false);
      _saveSettings();
    }
  }

  void _addError(String text) {
    setState(() {
      _messages.add(Message(
        id: const Uuid().v4(),
        role: 'assistant',
        content: text,
      ));
    });
  }

  // ─────────────────────── IMAGE GENERATION (Mobile + Web) ───────────────────────
  Future<void> _generateImageFromLastScene() async {
    if (_messages.isEmpty || _isLoading) return;

    final lastAiMessage = _messages.lastWhere((m) => m.role == 'assistant', orElse: () => _messages.last);
    String prompt = lastAiMessage.content;

    // Build prompt (your existing code)
    String style = switch (_imageStyle) {
      'anime' => 'anime style, ultra detailed vibrant colors',
      'fantasy' => 'fantasy oil painting dramatic lighting artstation',
      _ => 'photorealistic ultra realistic cinematic 8k',
    };
    String view = _firstPerson ? 'first-person POV immersive' : 'third-person view';
    String nsfw = _allowNsfw ? ', mature themes allowed' : ', safe for work no nudity';
    prompt = "Illustrate this exact scene: $prompt. $style, $view, masterpiece, best quality$nsfw";

    setState(() => _isLoading = true);

    if (!_isPremium) {
      _showRewardedAd(prompt);
    } else {
      await _actuallyGenerateImage(prompt);
    }

    setState(() => _isLoading = false);
    _saveSettings();
  }

  Future<void> _actuallyGenerateImage(String prompt) async {
    setState(() => _isLoading = true);

    // Choose correct model based on style
    final Map<String, String> modelMap = {
      'anime': 'cagliostos/anything-v4.5-vae-swapped',
      'fantasy': 'Lykon/dreamshaper-8',
      'realistic': 'stabilityai/stable-diffusion-xl-base-1.0',
    };
    final String model = modelMap[_imageStyle] ?? 'stabilityai/stable-diffusion-xl-base-1.0';

    final String stylePrefix = switch (_imageStyle) {
      'anime' => 'anime style, ultra detailed, sharp, vibrant colors,',
      'fantasy' => 'fantasy oil painting, artstation, dramatic lighting, highly detailed,',
      _ => 'photorealistic, ultra realistic, 8k, cinematic lighting,',
    };

    final String view = _firstPerson ? ', first-person POV' : '';
    final String nsfw = _allowNsfw ? ', mature allowed' : ', safe for work, no nudity';

    final fullPrompt = "$stylePrefix $prompt$view$nsfw, masterpiece, best quality";

    try {
      final response = await http.post(
        Uri.parse("https://router.huggingface.co/hf/inference/models/$model"),
        headers: {
          "Authorization": "Bearer $HF_API_KEY",
          "Content-Type": "application/json",
        },
        body: jsonEncode({
          "inputs": fullPrompt,
          "parameters": {"width": 768, "height": 1024}
        }),
      ).timeout(const Duration(seconds: 55));

      if (response.statusCode == 200) {
        final List<dynamic> result = jsonDecode(response.body);
        final String base64Image = result[0]; // HF returns base64 string directly
        final bytes = base64Decode(base64Image);

        String displayPath;
        if (kIsWeb) {
          final dataUrl = 'data:image/png;base64,$base64Image';
          displayPath = dataUrl;
          if (_autoSaveToGallery) {
            html.AnchorElement(href: dataUrl)
              ..setAttribute('download', 'novelbook_${DateTime.now().millisecondsSinceEpoch}.png')
              ..click();
          }
        } else {
          final dir = await getApplicationDocumentsDirectory();
          final file = File('${dir.path}/img_${DateTime.now().millisecondsSinceEpoch}.jpg');
          await file.writeAsBytes(bytes);
          displayPath = file.path;

          if (_autoSaveToGallery) {
            await ImageGallerySaverPlus.saveFile(file.path);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Image saved to gallery!')),
            );
          }
        }

        setState(() {
          _messages.add(Message(id: const Uuid().v4(), role: 'image', content: displayPath));
        });
      } else {
        final err = jsonDecode(response.body);
        _addError("Image failed: ${err['error'] ?? response.statusCode}");
      }
    } catch (e) {
      _addError("Image error: $e");
    } finally {
      setState(() => _isLoading = false);
      _saveSettings();
    }
  }

  // ─────────────────────── IMAGE SETTINGS DIALOG (Perfect) ───────────────────────
  void _showImageSettingsDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text("Image Settings", style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold)),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<String>(
              value: _imageStyle,
              dropdownColor: Colors.grey[850],
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(labelText: "Art Style", labelStyle: TextStyle(color: Colors.amber)),
              items: const [
                DropdownMenuItem(value: 'realistic', child: Text("Realistic")),
                DropdownMenuItem(value: 'anime', child: Text("Anime")),
                DropdownMenuItem(value: 'fantasy', child: Text("Fantasy Painting")),
              ],
              onChanged: (v) => setState(() => _imageStyle = v!),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              value: _textStyle,
              dropdownColor: Colors.grey[850],
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: "Text Style",
                labelStyle: TextStyle(color: Colors.amber),
              ),
              items: const [
                DropdownMenuItem(value: 'dnd', child: Text("D&D Action (choices)")),
                DropdownMenuItem(value: 'novel', child: Text("Immersive Novel")),
              ],
              onChanged: (v) => setState(() => _textStyle = v!),
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              title: const Text("Allow NSFW", style: TextStyle(color: Colors.white)),
              value: _allowNsfw,
              activeColor: Colors.deepPurple,
              onChanged: (v) => setState(() => _allowNsfw = v),
            ),
            SwitchListTile(
              title: const Text("First-person view", style: TextStyle(color: Colors.white)),
              value: _firstPerson,
              activeColor: Colors.deepPurple,
              onChanged: (v) => setState(() => _firstPerson = v),
            ),
            SwitchListTile(
              title: Text(kIsWeb ? "Auto-download image" : "Auto-save to Gallery", style: const TextStyle(color: Colors.white)),
              subtitle: Text(kIsWeb ? "Downloads folder" : "Photos/Gallery", style: const TextStyle(color: Colors.grey)),
              value: _autoSaveToGallery,
              activeColor: Colors.deepPurple,
              onChanged: (v) => setState(() => _autoSaveToGallery = v),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
          ElevatedButton.icon(
            icon: const Icon(Icons.auto_awesome),
            label: const Text("Generate"),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurple),
            onPressed: () {
              Navigator.pop(ctx);
              _generateImageFromLastScene();
            },
          ),
        ],
      ),
    );
  }

  bool get _showImageButton => _messages.isNotEmpty && _messages.last.role == 'assistant';

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Novelbook AI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark, colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple, brightness: Brightness.dark), scaffoldBackgroundColor: const Color(0xFF0D1117), useMaterial3: true),
      home: Scaffold(
        appBar: AppBar(
          title: const Text("Novelbook AI", style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold)),
          actions: [
            IconButton(icon: const Icon(Icons.refresh), onPressed: () => setState(() {_messages.clear(); _saveSettings();})),
          ],
        ),
        body: Column(children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _messages.length + (_isLoading ? 1 : 0),
              itemBuilder: (ctx, i) {
                if (i == _messages.length) return const Center(child: CircularProgressIndicator());

                final msg = _messages[i];
                if (msg.role == 'image') {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: kIsWeb
                            ? Image.network(msg.content, fit: BoxFit.cover, width: 320)
                            : Image.file(File(msg.content), fit: BoxFit.cover, width: 320),
                      ),
                    ),
                  );
                }

                final isUser = msg.role == 'user';
                return Align(
                  alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 6),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(color: isUser ? Colors.deepPurple[700] : Colors.grey[800], borderRadius: BorderRadius.circular(18)),
                    child: Text(msg.content, style: const TextStyle(fontSize: 16)),
                  ),
                );
              },
            ),
          ),
          if (_isAdLoaded && !_isPremium)
            SizedBox(height: _bannerAd.size.height.toDouble(), child: AdWidget(ad: _bannerAd)),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  decoration: InputDecoration(hintText: "What do you do next?", border: OutlineInputBorder(borderRadius: BorderRadius.circular(30)), filled: true, fillColor: Colors.grey[900]),
                  onSubmitted: (_) => _sendMessage(),
                ),
              ),
              const SizedBox(width: 8),
              if (_showImageButton)
                IconButton(icon: const Icon(Icons.image, color: Colors.amber, size: 32), onPressed: _showImageSettingsDialog),
              FloatingActionButton(backgroundColor: Colors.deepPurple, onPressed: _sendMessage, child: const Icon(Icons.send)),
            ]),
          ),
        ]),
      ),
    );
  }
}