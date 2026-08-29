#!/usr/bin/env python3
import gzip
import sqlite3
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
APP_DIR = ROOT / "japanese_card_generator"
JMDICT = APP_DIR / "JMdict_e_examp.gz"
JMNEDICT = APP_DIR / "JMnedict.xml.gz"
OUTPUT = APP_DIR / "JapaneseDictionary.sqlite"
XML_LANG = "{http://www.w3.org/XML/1998/namespace}lang"


def clean(value):
    return (value or "").strip()


def unique(values):
    seen = set()
    result = []
    for value in values:
        value = clean(value)
        if value and value not in seen:
            seen.add(value)
            result.append(value)
    return result


def kana_to_hiragana(value):
    chars = []
    for char in value:
        codepoint = ord(char)
        if 0x30A1 <= codepoint <= 0x30F6:
            chars.append(chr(codepoint - 0x60))
        else:
            chars.append(char)
    return "".join(chars)


def text_list(elem, path):
    return [clean(child.text) for child in elem.findall(path) if clean(child.text)]


def english_glosses(sense):
    return [
        clean(gloss.text)
        for gloss in sense.findall("gloss")
        if clean(gloss.text) and gloss.attrib.get(XML_LANG, gloss.attrib.get("lang", "eng")) == "eng"
    ]


def english_translations(trans):
    return [
        clean(detail.text)
        for detail in trans.findall("trans_det")
        if clean(detail.text) and detail.attrib.get(XML_LANG, "eng") == "eng"
    ]


def entry_priority(elem):
    priority = 0
    if elem.findall("./k_ele/ke_pri") or elem.findall("./r_ele/re_pri"):
        priority += 100
    for pri in text_list(elem, "./k_ele/ke_pri") + text_list(elem, "./r_ele/re_pri"):
        if "ichi1" in pri or "news1" in pri or "spec1" in pri:
            priority += 50
        elif pri.endswith("1"):
            priority += 20
    return priority


def category_from_pos(parts_of_speech):
    values = " ".join(parts_of_speech).lower()
    if "verb" in values:
        return "Verbs"
    if "adjective" in values or "adjectival" in values:
        return "Adjectives"
    if "expression" in values or "phrase" in values:
        return "Phrases"
    if "counter" in values or "numeric" in values or "number" in values:
        return "Time-Numbers"
    if "proper noun" in values or "pronoun" in values:
        return "Names"
    return "Nouns"


def themes_from_tags(tags, category):
    joined = " ".join(tags).lower()
    themes = []
    checks = [
        ("Food/Drink", ["food", "cooking", "drink"]),
        ("Places", ["geography", "place", "station", "building", "facility"]),
        ("Transport", ["railway", "transport", "vehicle", "ship"]),
        ("Body/Health", ["medicine", "anatomy", "body", "health", "disease"]),
        ("Animals", ["animal", "zoology", "bird", "fish"]),
        ("Weather", ["meteorology", "weather"]),
        ("Study/Language", ["linguistics", "language", "grammar"]),
        ("Work/Society", ["business", "law", "economics", "politics", "military"]),
        ("Activities/Leisure", ["sports", "game", "music", "art"]),
        ("Time", ["time", "calendar"]),
    ]
    for theme, needles in checks:
        if any(needle in joined for needle in needles):
            themes.append(theme)
    if category == "Time-Numbers":
        themes.append("Time")
    if "colloquialism" in joined or "slang" in joined or "vulgar" in joined:
        themes.append("Activities/Leisure")
    return unique(themes)


def first_example(sense):
    for example in sense.findall("example"):
        japanese = ""
        english = ""
        for sentence in example.findall("ex_sent"):
            lang = sentence.attrib.get(XML_LANG, "eng")
            if lang == "jpn":
                japanese = clean(sentence.text)
            elif lang == "eng":
                english = clean(sentence.text)
        if japanese and english:
            return japanese, english
    return "", ""


def matching_reading(entry, expression):
    readings = entry.findall("r_ele")
    for reading in readings:
        restrictions = text_list(reading, "re_restr")
        if not restrictions or expression in restrictions:
            return kana_to_hiragana(clean(reading.findtext("reb")))
    if readings:
        return kana_to_hiragana(clean(readings[0].findtext("reb")))
    return ""


def jmdict_rows():
    with gzip.open(JMDICT, "rb") as file:
        for _, entry in ET.iterparse(file, events=("end",)):
            if entry.tag != "entry":
                continue

            kanji = text_list(entry, "./k_ele/keb")
            readings = text_list(entry, "./r_ele/reb")
            expressions = kanji or readings
            if not expressions or not readings:
                entry.clear()
                continue

            senses = entry.findall("sense")
            first_english_sense = None
            for sense in senses:
                if english_glosses(sense):
                    first_english_sense = sense
                    break
            if first_english_sense is None:
                entry.clear()
                continue

            glosses = unique(english_glosses(first_english_sense))
            if not glosses:
                entry.clear()
                continue

            pos = unique(text_list(first_english_sense, "pos"))
            tags = unique(
                text_list(first_english_sense, "misc")
                + text_list(first_english_sense, "field")
                + text_list(first_english_sense, "dial")
                + text_list(first_english_sense, "s_inf")
            )
            category = category_from_pos(pos)
            themes = themes_from_tags(pos + tags, category)
            example_japanese, example_english = first_example(first_english_sense)
            expression = expressions[0]

            yield {
                "source": "jmdict",
                "source_id": clean(entry.findtext("ent_seq")),
                "expression": expression,
                "reading": matching_reading(entry, expression),
                "meaning": "; ".join(glosses[:3]),
                "part_of_speech": ", ".join(pos),
                "tags": ", ".join(tags),
                "category": category,
                "themes": ", ".join(themes),
                "example_japanese": example_japanese,
                "example_english": example_english,
                "priority": entry_priority(entry),
                "keys": unique(expressions + readings),
            }
            entry.clear()


def jmnedict_rows():
    with gzip.open(JMNEDICT, "rb") as file:
        for _, entry in ET.iterparse(file, events=("end",)):
            if entry.tag != "entry":
                continue

            kanji = text_list(entry, "./k_ele/keb")
            readings = text_list(entry, "./r_ele/reb")
            expressions = kanji or readings
            if not expressions or not readings:
                entry.clear()
                continue

            translations = entry.findall("trans")
            if not translations:
                entry.clear()
                continue

            name_types = unique(text_list(translations[0], "name_type"))
            meanings = unique(english_translations(translations[0]))
            if not meanings:
                entry.clear()
                continue

            tags = name_types
            themes = ["Places"] if any("place name" in tag or "station" in tag for tag in tags) else ["Names"]
            expression = expressions[0]

            yield {
                "source": "jmnedict",
                "source_id": clean(entry.findtext("ent_seq")),
                "expression": expression,
                "reading": matching_reading(entry, expression),
                "meaning": "; ".join(meanings[:3]),
                "part_of_speech": ", ".join(name_types),
                "tags": ", ".join(tags),
                "category": "Names",
                "themes": ", ".join(themes),
                "example_japanese": "",
                "example_english": "",
                "priority": entry_priority(entry),
                "keys": unique(expressions + readings),
            }
            entry.clear()


def build_database():
    if OUTPUT.exists():
        OUTPUT.unlink()

    connection = sqlite3.connect(OUTPUT)
    connection.execute("PRAGMA journal_mode = OFF")
    connection.execute("PRAGMA synchronous = OFF")
    connection.executescript(
        """
        CREATE TABLE entries (
            id INTEGER PRIMARY KEY,
            source TEXT NOT NULL,
            source_id TEXT NOT NULL,
            expression TEXT NOT NULL,
            reading TEXT NOT NULL,
            meaning TEXT NOT NULL,
            part_of_speech TEXT NOT NULL,
            tags TEXT NOT NULL,
            category TEXT NOT NULL,
            themes TEXT NOT NULL,
            example_japanese TEXT NOT NULL,
            example_english TEXT NOT NULL,
            priority INTEGER NOT NULL
        );

        CREATE TABLE search_keys (
            key TEXT NOT NULL,
            entry_id INTEGER NOT NULL REFERENCES entries(id)
        );
        """
    )

    entry_insert = """
        INSERT INTO entries (
            source, source_id, expression, reading, meaning, part_of_speech,
            tags, category, themes, example_japanese, example_english, priority
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """
    key_insert = "INSERT INTO search_keys (key, entry_id) VALUES (?, ?)"

    with connection:
        for rows in (jmdict_rows(), jmnedict_rows()):
            for row in rows:
                cursor = connection.execute(
                    entry_insert,
                    (
                        row["source"],
                        row["source_id"],
                        row["expression"],
                        row["reading"],
                        row["meaning"],
                        row["part_of_speech"],
                        row["tags"],
                        row["category"],
                        row["themes"],
                        row["example_japanese"],
                        row["example_english"],
                        row["priority"],
                    ),
                )
                entry_id = cursor.lastrowid
                connection.executemany(key_insert, ((key, entry_id) for key in row["keys"]))

        connection.execute("CREATE INDEX idx_search_keys_key ON search_keys(key)")
        connection.execute("CREATE INDEX idx_entries_source_priority ON entries(source, priority DESC)")

    connection.execute("VACUUM")
    connection.close()


if __name__ == "__main__":
    try:
        build_database()
    except Exception as error:
        print(error, file=sys.stderr)
        sys.exit(1)
    print(OUTPUT)
