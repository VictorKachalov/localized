import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart' show ArgParser;
import 'package:http/http.dart' as http;
import 'package:translator/translator.dart';
import 'package:tuple/tuple.dart';

// supported translation providers
// GoogleTest should be on the first place
const _providerList = [
  "GoogleTest",
  "Google",
  "Yandex",
];
final Map<String, Function> _providerTranslateFunctionMap = {
  _providerList[0]: _translateGoogleTest,
  _providerList[1]: _translateGoogle,
  _providerList[2]: _translateYandex,
};
final Map<String, String> _providerDescriptionMap = {
  _providerList[0]: "Google API through a back door",
  _providerList[1]: "Google using API key",
  _providerList[2]: "Yandex using folder ID and IAM token",
};

/// Creates examples of localized files as well as localizes strings
/// by translating them using different providers.
/// See README.md and usage for details
void main(List<String> args) {
  final parser = ArgParser(allowTrailingOptions: true);
  parser.addFlag('create',
      abbr: 'c',
      help: 'Create sample localization files',
      defaultsTo: false,
      negatable: false);
  parser.addFlag('translate',
      abbr: 't',
      help: 'Translate localization files',
      defaultsTo: false,
      negatable: false);
  parser.addMultiOption('languageCodes', abbr: 'l', help: 'Language codes');
  parser.addOption('dirPath',
      abbr: 'd', defaultsTo: 'assets/i18n', help: 'i18n files directory');
  parser.addOption('provider',
      abbr: 'p',
      defaultsTo: 'GoogleTest',
      allowed: _providerList,
      allowedHelp: _providerDescriptionMap,
      help: 'Provider of translation API');
  parser.addOption('key', abbr: 'k', help: 'Google Project API key');
  parser.addOption('folder_id', abbr: 'f', help: 'Yandex Folder ID');
  parser.addOption('token', abbr: 'i', help: 'Yandex IAM token');
  parser.addOption('number',
      abbr: 'n',
      defaultsTo: '1',
      help: 'The number of strings to translate in one request');
  final createFiles = parser.parse(args)['create'];
  final translateFiles = parser.parse(args)['translate'];
  if ((createFiles && translateFiles) || (!createFiles && !translateFiles)) {
    stdout.writeln('${parser.usage}');
    stdout.writeln(
        'You have to choose between -create and -translate. Exiting...');
    exit(0);
  }
  final langCodes = parser.parse(args)['languageCodes'];
  final dirPath = parser.parse(args)['dirPath'];
  final Map<String, String> options = Map();
  if (parser.parse(args)['provider'] != null)
    options['provider'] = parser.parse(args)['provider'];
  if (parser.parse(args)['key'] != null)
    options['key'] = parser.parse(args)['key'];
  if (parser.parse(args)['number'] != null)
    options['number'] = parser.parse(args)['number'];
  if (parser.parse(args)['folder_id'] != null)
    options['folder_id'] = parser.parse(args)['folder_id'];
  if (parser.parse(args)['token'] != null)
    options['token'] = parser.parse(args)['token'];
  // translation from English is better
  langCodes.sort((a, b) => a == 'en'
      ? -1
      : b == 'en'
          ? 1
          : 0);
  // creating examples or translating strings?
  if (createFiles) _createLocalizedFiles(langCodes, dirPath);
  if (translateFiles) _translateLocalizedFiles(langCodes, dirPath, options);
}

// main function to translate
void _translateLocalizedFiles(
    List<String> langCodes, String dirPath, Map<String, String> options) async {
  final provider = options['provider'];
  if (provider == null || !_providerList.contains(provider)) {
    stdout.writeln('No valid translation provider set. Exiting...');
    exit(0);
  }
  if (langCodes.length < 2) {
    stdout.writeln(
        'For translation you have to provide at least two langCodes. Exiting...');
    exit(0);
  }
  final directory = Directory(dirPath);
  if (!directory.existsSync()) {
    stdout.writeln('No directory found. Exiting...');
    exit(0);
  }
  final files = directory.listSync();
  if (files.isEmpty) {
    stdout.writeln('No localization files found. Exiting...');
    exit(0);
  }
  // loading keys and strings to langStringMap for each language
  final Map<String, Map<String, String>> langStringMap = Map();
  for (final lang in langCodes) {
    if (!_isSupported(lang)) {
      stdout.writeln('Language code $lang is not supported.');
      continue;
    }
    langStringMap[lang] = await _loadStrings(lang, dirPath);
  }
  // looking for and collecting strings that exist for one language, but don't for another
  // we need such a strange structure to translate a bunch of strings at once,
  // because this is much quicker
  // Map of <targetLang, sourceLang> to List<key>>
  final Map<Tuple2<String, String>, List<String>> toTranslateMap = Map();
  langStringMap.forEach((sourceLang, sourceStringMap) {
    sourceStringMap.forEach((sourceKey, sourceString) {
      langStringMap.forEach((targetLang, targetStringMap) {
        if (sourceLang != targetLang) {
          if (sourceStringMap[sourceKey].isNotEmpty &&
              !targetStringMap.containsKey(sourceKey)) {
            final tuple = Tuple2(targetLang, sourceLang);
            if (toTranslateMap[tuple] == null) toTranslateMap[tuple] = List();
            toTranslateMap[tuple].add(sourceKey);
          }
        }
      });
    });
  });
  if (toTranslateMap.isEmpty) {
    stdout.writeln('No strings need to be translated. Exiting...');
    exit(0);
  }
  // to check performance
  String date = DateTime.now().toString();
  stdout.writeln('Translation starts - $date');
  // different functions and arguments for different providers
  if (provider.compareTo(_providerList[0]) == 0)
    await _providerTranslateFunctionMap[provider](
        langStringMap, toTranslateMap);
  else
    await _batchTranslate(langStringMap, toTranslateMap, options);

  // to check performance
  date = DateTime.now().toString();
  stdout.writeln('Translation ends   - $date');
  _updateContent(langStringMap, dirPath);
}

// see https://github.com/gabrielpacheco23, thanks to Gabriel Pacheco
Future<void> _translateGoogleTest(
    Map<String, Map<String, String>> langStringMap,
    Map<Tuple2<String, String>, List<String>> toTranslateMap) async {
  final gtr = GoogleTranslator();
  await Future.forEach(toTranslateMap.entries, (toTranslate) async {
    final targetLang = toTranslate.key.item1;
    final sourceLang = toTranslate.key.item2;
    final keyList = toTranslate.value;
    await Future.forEach(keyList, (key) async {
      final sourceString = langStringMap[sourceLang][key];
      langStringMap[targetLang][key] =
          (await gtr.translate(sourceString, from: sourceLang, to: targetLang))
              .text;
    });
  });
}

// langStringMap is a map of a language to <key, string>
// toTranslateMap is a map of <targetLang, sourceLang> to List<key>> - strings to translate
Future<void> _batchTranslate(
    Map<String, Map<String, String>> langStringMap,
    Map<Tuple2<String, String>, List<String>> toTranslateMap,
    Map<String, String> options) async {
  final numStringsAtOnce = int.parse(options['number']);
  String provider = options['provider'];
  await Future.forEach(toTranslateMap.entries, (toTranslate) async {
    final targetLang = toTranslate.key.item1;
    final sourceLang = toTranslate.key.item2;
    final keyList = toTranslate.value;
    final List<String> stringInOutList = List();
    int num = 0;
    for (var key1 in keyList) {
      stringInOutList.add(langStringMap[sourceLang][key1]);
      ++num;
      if (num > 0 && num % numStringsAtOnce == 0) {
        await _providerTranslateFunctionMap[provider](
            stringInOutList, sourceLang, targetLang, options);
        for (int index = 0; index < stringInOutList.length; index++) {
          langStringMap[targetLang]
                  [keyList[num - stringInOutList.length + index]] =
              stringInOutList[index];
        }
        stringInOutList.clear();
      }
    }
    if (stringInOutList.isNotEmpty) {
      await _providerTranslateFunctionMap[provider](
          stringInOutList, sourceLang, targetLang, options);
      for (int index = 0; index < stringInOutList.length; index++) {
        langStringMap[targetLang]
                [keyList[num - stringInOutList.length + index]] =
            stringInOutList[index];
      }
    }
  });
}

// Google Translate
// https://cloud.google.com/translate/docs/basic/translating-text
// langStringMap is a map of a language to <key, string>
// toTranslateMap is a map of <targetLang, sourceLang> to List<key>> - strings to translate
// https://translation.googleapis.com/language/translate/v2?target={YOUR_LANGUAGE}&key=${API_KEY}&q=${TEXT}
Future<void> _translateGoogle(List<String> stringInOutList, String sourceLang,
    String targetLang, Map<String, String> options) async {
  final googleProjectKey = options['key'];
  if (googleProjectKey == null) {
    stdout.writeln('No Google project key provided. Exiting...');
    exit(0);
  }
  const baseUrl = 'translation.googleapis.com';
  const path = 'language/translate/v2';
  // It's impossible to add several equal query parameters using the 'parameters' map
  final queryStart =
      'format=text&target=$targetLang&source=$sourceLang&key=$googleProjectKey';
  var queryEnd = '';
  stringInOutList.forEach((text) {
    queryEnd = queryEnd + '&q=$text';
  });
  try {
    final url = Uri.https(baseUrl, path).replace(query: queryStart + queryEnd);
    final data = await http.get(url);
    if (data.statusCode != 200) {
      throw http.ClientException('Error ${data.statusCode}: ${data.body}', url);
    }
    stringInOutList.clear();
    final mapList = jsonDecode(data.body)["data"]["translations"];
    mapList.forEach((map) {
      stringInOutList.add(map['translatedText']);
    });
  } catch (e) {
    stdout.writeln(
        'Cannot translate some strings from $sourceLang to $targetLang. An excaption occurs:\n$e');
    stringInOutList.clear();
  }
}

// Yandex Translate
// https://cloud.yandex.com/docs/iam/operations/iam-token/create
// langStringMap is a map of a language to <key, string>
// toTranslateMap is a map of <targetLang, sourceLang> to List<key>> - strings to translate
Future<void> _translateYandex(List<String> stringInOutList, String sourceLang,
    String targetLang, Map<String, String> options) async {
  final yandexFilderID = options['folder_id'];
  final yandexIAMToken = options['token'];
  if (yandexFilderID == null || yandexIAMToken == null) {
    stdout.writeln('No Yandex Folder ID or IAM token provided. Exiting...');
    exit(0);
  }
  const url = "https://translate.api.cloud.yandex.net/translate/v2/translate";
  final Map<String, String> headers = {
    'Content-type': 'application/json',
    'Authorization': "Bearer " + yandexIAMToken,
  };
  try {
    final body = json.encode({
      "sourceLanguageCode": sourceLang,
      "format": "PLAIN_TEXT",
      "folder_id": yandexFilderID,
      "texts": stringInOutList,
      "targetLanguageCode": targetLang
    });
    final data = await http.post(url, body: body, headers: headers);
    if (data.statusCode != 200) {
      throw http.ClientException('Error ${data.statusCode}: ${data.body}');
    }
    stringInOutList.clear();
    final mapList = jsonDecode(data.body)["translations"];
    mapList.forEach((map) {
      stringInOutList.add(map['text']);
    });
  } catch (e) {
    stdout.writeln(
        'Cannot translate some strings from $sourceLang to $targetLang. An excaption occurs:\n$e');
    stringInOutList.clear();
  }
}

// Loading of strings from language files
Future<Map<String, String>> _loadStrings(String lang, String dirPath) async {
  Map<String, String> localizedStrings = Map();
  try {
    final file = File('$dirPath/$lang.json');
    if (!await file.exists()) return localizedStrings;
    final jsonString = await file.readAsString();
    if (jsonString.isEmpty) return localizedStrings;
    final Map<String, dynamic> jsonMap = json.decode(jsonString);
    localizedStrings = jsonMap.map((key, value) {
      return MapEntry(key, value.toString());
    });
  } catch (e) {
    stdout.writeln(
        'Cannot load strings from $dirPath/$lang.json file. An excaption occurs:\n$e.');
  }
  return localizedStrings;
}

// Writing translated files
void _updateContent(Map<String, Map<String, String>> langStrMap, dirPath) {
  Future.forEach(langStrMap.entries, (langStrMapEntry) async {
    try {
      await File('$dirPath/${langStrMapEntry.key}.json')
          .create(recursive: true)
          .then((file) {
        stdout.writeln('Rewriting file: ${file.path}');
        file.writeAsString(json.encode(langStrMapEntry.value));
      });
    } catch (e) {
      stdout.writeln(
          'Cannot update $dirPath/${langStrMapEntry.key}.json file. An excaption occurs:\n$e.');
    }
  });
}

bool _isSupported(String locale) => kSupportedLanguages.contains(locale);

void _createLocalizedFiles(List<String> langCodes, String dirPath) {
  if (langCodes.isEmpty) {
    stdout.writeln(
        'To create files you need to provide at least one language code. Exiting...');
    exit(0);
  }
  final directory = Directory(dirPath);
  if (!directory.existsSync()) {
    _createContent(directory, langCodes, dirPath);
  } else {
    _rewrite(directory, langCodes, dirPath);
  }
}

void _rewrite(Directory directory, List<String> langCodes, String dirPath) {
  stdout.writeln(
      'The assets with i18n exist. Do you want to override it? [Y/N]:');
  final line =
      stdin.readLineSync(encoding: Encoding.getByName('utf-8')).toLowerCase();
  switch (line) {
    case 'y':
      _createContent(directory, langCodes, dirPath);
      break;
    case 'n':
      exit(0);
      break;
    default:
      _rewrite(directory, langCodes, dirPath);
      break;
  }
}

void _createContent(
    Directory directory, List<String> langCodes, String dirPath) {
  directory.create(recursive: true).then((directory) {
    for (final lang in langCodes) {
      if (!_isSupported(lang)) {
        stdout.writeln('Language code $lang is not supported.');
        continue;
      }
      final file = File('$dirPath/$lang.json');
      stdout.writeln('Creating file: ${file.path}');
      file.create(recursive: true).then((file) => file.writeAsString(
          '{\n  "title": "value",\n  "amount_of_clicks": "value",\n  "increase": "value"\n}'));
    }
  });
}

// copy from the dart file
final Set<String> kSupportedLanguages = HashSet<String>.from(const <String>[
  'af', // Afrikaans
  'am', // Amharic
  'ar', // Arabic
  'as', // Assamese
  'az', // Azerbaijani
  'be', // Belarusian
  'bg', // Bulgarian
  'bn', // Bengali Bangla
  'bs', // Bosnian
  'ca', // Catalan Valencian
  'cs', // Czech
  'da', // Danish
  'de', // German
  'el', // Modern Greek
  'en', // English
  'es', // Spanish Castilian
  'et', // Estonian
  'eu', // Basque
  'fa', // Persian
  'fi', // Finnish
  'fil', // Filipino Pilipino
  'fr', // French
  'gl', // Galician
  'gsw', // Swiss German Alemannic Alsatian
  'gu', // Gujarati
  'he', // Hebrew
  'hi', // Hindi
  'hr', // Croatian
  'hu', // Hungarian
  'hy', // Armenian
  'id', // Indonesian
  'is', // Icelandic
  'it', // Italian
  'ja', // Japanese
  'ka', // Georgian
  'kk', // Kazakh
  'km', // Khmer Central Khmer
  'kn', // Kannada
  'ko', // Korean
  'ky', // Kirghiz Kyrgyz
  'lo', // Lao
  'lt', // Lithuanian
  'lv', // Latvian
  'mk', // Macedonian
  'ml', // Malayalam
  'mn', // Mongolian
  'mr', // Marathi
  'ms', // Malay
  'my', // Burmese
  'nb', // Norwegian Bokmål
  'ne', // Nepali
  'nl', // Dutch Flemish
  'no', // Norwegian
  'or', // Oriya
  'pa', // Panjabi Punjabi
  'pl', // Polish
  'ps', // Pushto Pashto
  'pt', // Portuguese
  'ro', // Romanian Moldavian Moldovan
  'ru', // Russian
  'si', // Sinhala Sinhalese
  'sk', // Slovak
  'sl', // Slovenian
  'sq', // Albanian
  'sr', // Serbian
  'sv', // Swedish
  'sw', // Swahili
  'ta', // Tamil
  'te', // Telugu
  'th', // Thai
  'tl', // Tagalog
  'tr', // Turkish
  'uk', // Ukrainian
  'ur', // Urdu
  'uz', // Uzbek
  'vi', // Vietnamese
  'zh', // Chinese
  'zu', // Zulu
]);
