# Japanese Card Generator

A Swift iOS app that lets you create Japanese vocabulary flashcards and send them to AnkiMobile.

Enter an expression, and the app looks up dictionary definitions from JMdict (https://github.com/yomidevs/jmdict-yomitan). You can refine each field and add your own notes. 

This app is useful for Japanese language mining — I built it while visting Japan to quickly add words that I learnt when I didn't have time to enter fields myself.

## How it works
1. Enter an expression (word/phrase) and tap Generate.
2. The app queries an offline JMdict-derived SQLite database and returns definitions and readings.
3. Pick a result (if multiple) and refine the fields as needed.
4. Optionally attach an image to the Notes field
5. Choose your Anki deck and note type in Settings (fetched from AnkiMobile).
6. Tap “Add to Anki” to open AnkiMobile with your filled fields.

## Intended flashcard fields
- Expression: The target Japanese word or phrase (e.g., 食べる).
- Reading: Reading for the expression (e.g., たべる).
- Meaning: nglish definition (e.g., “to eat”).
- Category: A label to group cards (e.g., “Verbs”).
- Example Japanese: A natural example sentence using the expression (e.g., 今日は寿司を食べる).
- Example English: The English translation of the example (e.g., “I’ll eat sushi today.”).
- Notes: Any personal notes or nuances. Can optionally attach an image to this field.
