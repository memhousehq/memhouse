<!-- SPDX-License-Identifier: Apache-2.0 -->
# Review notes for the draft language packs

Every pack except English is a **draft**: it passes its labelled test set
(`languages/tests/<code>.yaml`) and has not been reviewed by a speaker of the language. These
notes list, per language, the choices a reviewer should look at first: markers that are also
ordinary words, forms that are probably missing, and readings of dates and numbers. A pack is
marked `status = "stable"` once a speaker has reviewed it
([docs/languages.md](../docs/languages.md#writing-and-testing-a-pack)).

## What the format cannot express yet (several languages)

- "A week ago" without a number ("viikko sitten", "tydzień temu", "prije tjedan dana") is not a
  centred time window: the `ago` template needs `{num}`. Some packs read the instrumental form
  ("przed tygodniem") through `past`, as "since one unit ago".
- `between` with a postposition after both items ("A:n ja B:n välillä", "A és B között") only
  splits one-word items.
- Words for "last year" and "this year" that carry no unit word ("tavaly", "idén", "πέρσι",
  "φέτος", "tänavu") are not read as time windows.
- An identifier with a case suffix joined by a hyphen ("#4521-es", "A-1001-ga") is read with the
  suffix; a year with a suffix ("2019-ben") is read as an identifier.
- A month whose name is also another word or a personal name ("mai", "май", "maja", "mája",
  "julija") is read as a month only after a preposition or next to a day or year; a day before
  such a month can give the whole month instead of the day.

## Shared choices

- "Now" as a correction marker (de `jetzt`, nl/da/sv `nu`, fi `nyt`, hu `most`, et `nüüd`):
  "bought a new car now" reads as a correction. Several packs (ro, hr, bg) accept it only next
  to a verb.
- The future auxiliary as a plan marker (hr `ću/će`, bg `ще`, el `θα`, sl `bo` + participle, pl
  `będzie`, cs `bude`): every future statement is held.
- "Wants" as a plan marker (de `will`, nl `wil`, da `vil`, sv `vill`, hr `želi`).
- "Can / may" is left out of speculation where the same word means "is able to" (pl `może`, bg
  `може да`, el `μπορεί να`, ro `poate`, et `võib`, sl `mogoče`).
- "Must" is not a plan marker, so that "must always" stays an instruction (ro `trebuie să`, hu
  `kell`, fi `täytyy`, da `skal`).
- Value words are merged over the enabled packs, so number words of one language can collide
  with words of another (it `due`, fr `cent`, es `once`).
- Imperatives that are also third-person forms without a subject (es, pt, it `usa`, `evita`)
  read as instructions.
- Imperatives that are also third-person past forms (bg `забрави`, `изпрати`; el `αγνόησε`,
  `ξέχασε`) make a narrative sentence such as "the customer forgot all the rules" an injection
  false alarm.

## Bulgarian (bg)

- Left out of speculation: `може да`, the particle `май`, `сигурно`.
- Bare third-person aorists (`купи`, `посети`) are event markers and also imperatives.
- `смени`/`промени`/`замени` are corrections only with an ending; `мина на` (switched to) also
  catches "мина на преглед"; `вече`/`сега` only with a negation or a listed verb.
- Bare `Не …` prohibitions are not instruction markers.
- `миналия`/`предишния` mean the previous calendar month or year; `последния`/`изминалия` a
  rolling period.
- `[detect] letters` is the whole alphabet: it would overlap with another Cyrillic pack.

## Croatian (hr)

- `nekad(a)` is a correction marker ("used to") but can mean "sometimes"; `sada` counts only
  next to a listed verb; "used to" with `prije` covers a few verbs.
- `koristi` at the start reads as an instruction, but is also third-person present.
- Events are the l-participles of about 60 verbs.
- Months: Croatian names only, in four cases; international names are left out ("Marta",
  "Maja" are personal names). "u subotu" is read as the most recent Saturday.
- Role hijack needs a second-person form; "sada si" is left out (`si` is also reflexive).

## Czech (cs)

- Left out of speculation: `asi` (also "about"), `třeba`.
- "No longer" is `už`/`již` directly before a verb negated with `ne-`; words in between are not
  caught.
- `oprava`/`korekce` are corrections only as headings; `dříve` is kept though it also means
  "earlier"; `brzy` is a plan marker only as `už brzy`.
- Future: `bude` + infinitive in vowel + `t`; -st/-ct infinitives are missed. Negative
  imperatives such as `nepiš` are missed.
- `let` is a year form and also "flight"; `září` is also a verb form.

## Danish (da)

- `skal` alone is not a plan marker (also "must"); `på <weekday>` is (the coming day); `i
  lørdags` is the last-weekday form. "i weekenden" and "i år" are not time phrases.
- `tog` (train) and `ansat` are left out of events; `fik`, `gav`, `lavede`, `gjorde` are in.
- `tidligere` is a correction marker and also "former". An instruction is also read from
  "<verb> altid/aldrig/ikke" at the start, which misreads subject-dropped notes.
- The numeral one is left out of quantities (it is the article).

## Dutch (nl)

- `mogelijk` is left out of speculation ("zo snel mogelijk"); `plant` counts only with "om" or
  a "te" clause; `vroeger` is a correction marker and also "earlier".
- "de afgelopen maand" is the last 30 days; only "vorige maand" is the calendar month.
- `regels` as an injection target also means "lines"; "vergeet de regels" alone is not caught
  (the pattern needs alle/je after the verb, so that "vergeet niet" stays clean).

## Estonian (et)

- Bare `võib`, `ehk` and `äkki` are left out of speculation; `vist`, `küllap`, `arvan` are in.
- `enam` is a correction only with a negation; `nüüd`, `varem`, `kolis`, `vahetas` are
  corrections.
- Events are an explicit verb list (a general "-s" past collides with the inessive); the
  impersonal past is a short list.
- `kuus` is "six" and "in a month"; "eelmisel kuul" is calendar, "viimase kuu jooksul" rolling.
- Words to check: `juuruta` (deploy), "pöördumine" (ticket), `süsteemiviip` (system prompt).

## Finnish (fi)

- Speculation includes `saattaa` (also "to escort"), `kai`, `varmaan`, `taitaa` and "jos … -isi".
- `pitää` is a preference only as "pitää X-sta"; `muista` + infinitive is a plan for some
  infinitive types only.
- `uusi` (renewed) is left out of events; the passive past is a verb list.
- `kuu` is month and moon; "viime kuussa" is calendar, "viimeisen kuukauden aikana" rolling.
- `number_suffixes` (`v`, `kk`, `pv`, `vk`, `kpl`, `krs`) are a guess.

## French (fr)

- `finalement`, `en fait`, `maintenant` and `désormais` are correction markers and common words;
  "est passé(e) à" also matches "est passée à la boulangerie".
- `veut` also matches "veut dire"; "va + infinitive" would match "ça va super"; the future tense
  is a list of common stems.
- Events: "a/ont + word in -é" is generic ("a pitié" matches).
- A statement that opens with "Ne"/"N'" reads as an instruction.
- `neuf` is left out of quantities (also "new"); "le mois dernier" is the calendar month, "le
  dernier mois" the last 30 days.

## German (de)

- `jetzt`, `inzwischen`, `mittlerweile`, `eigentlich`, `früher` and `statt` are bare correction
  markers; `will`, `möchte` and `werde` are plan markers; "wird" counts only before a listed
  infinitive (it is also the passive auxiliary).
- `morgen` is a plan marker only in unambiguous forms ("ab morgen", "morgen früh"): it is also
  "morning".
- `gern(e)` and `lieber` are preference markers; "muss" alone is not a plan marker.
- Events are a list of participles and preterites; "war" is left out.

## Greek (el)

- Patterns accept accented, unaccented and upper-case text; the plain word lists are mostly
  accented only.
- `πια`, `πλέον`, `τελικά` and `αντί` are bare correction markers (`τελικά` may be too broad);
  `πέρασε σε` also catches "πέρασε στο πανεπιστήμιο".
- Events: the aorist of about 45 verbs and a generic perfect; perfects such as "έχει πάει" are
  missed.
- Τρίτη, Τετάρτη and Πέμπτη are also ordinals: "την τρίτη φορά" gives a false time window.
- The system-prompt pattern expects Latin "system prompt" or "προτροπή/μήνυμα/οδηγίες
  συστήματος".

## Irish (ga)

- A sentence-initial unlenited verb root is read as an imperative (Seol, Cuir, Déan); verbs that
  cannot lenite count only with "i gcónaí / riamh / choíche". "Ná" at the start is always an
  instruction.
- Any word in -faidh/-fidh/-óidh/-eoidh is a plan, which includes "caithfidh" (must); "beidh"
  is left out. "chun" counts only as "tá (mé/sé/…) chun".
- `sé` (six, also "he") is left out of the number lists; "coicís ó shin" is not read.
- Unit and weekday forms cover lenition and eclipsis: check for missed forms.
- Terminology guesses: "imscar" (deploy), "tiomnú" (commit), "treoracha córais / leid chórais"
  (system prompt).

## Italian (it)

- Events: "ha/hanno + word in -ato/-uto/-ito" is generic ("ha debiti" matches); the passato
  remoto is left out.
- `ora` is a correction only at the start or next to a listed verb (also "hour"); "è passata a"
  also matches "è passata a trovarmi".
- The future needs two letters before the ending; second person "-erai" is not generic.
  "Tra/fra + number + unit" is a plan marker.
- `sei` is left out of quantities (also "you are"). Abbreviated months need a full stop.

## Hungarian (hu)

- The potential suffix -hat/-het is not a speculation marker; `szerintem`, `elvileg`,
  `bizonyára` are.
- Future is "fog" + infinitive; bare `lesz` is not a plan marker. `szeret` is preference,
  `szeretne` plan.
- `adott` is left out of events; `ezelőtt` and `tavaly` alone mark an event.
- `hét` is "week" and "seven"; "múlt hónapban" is calendar, "az elmúlt hónapban" rolling; a
  bare "vasárnap" is not read.
- Role hijack needs the pronoun "te" (`vagy` is also "or").

## Latvian (lv)

- The genitives "marta" and "maija" are not read as months (Marta and Maija are names).
- `laikam`, "it kā", `esot` are hedges; bare `tagad`, `agrāk`, `vairs`, `nevis` are correction
  markers.
- The debitive ("jānopērk") is not a plan marker; the future is a closed stem list.
- Negative imperatives of -o and -ā verbs are not covered; compound perfects are mostly missed.
- "sistēmas uzvedne" is assumed for "system prompt"; `vai` ("or") is also the question particle.

## Lithuanian (lt)

- Month forms "kovo/kovą", "balandį", "liepą" are also other words; the nominatives are left out.
- `gali` alone is not a hedge; bare `dabar` and `anksčiau` are correction markers.
- The future is a closed list of about 35 stems; "reikia" and "turi" are left out.
- Past forms cover the first and third person; participles are not covered.
- The system-prompt term is a guess; `ar` ("or") is also the question particle.

## Maltese (mt)

- Most weekday names are also other words: a weekday is read only after "nhar (ta')" or before
  "li għadda". "il-Ġimgħa li għadda" reads as last Friday and as last week.
- "se / ser / sejjer" are plan markers; "sa" and "ħa" are left out. `jista'` alone is not a
  hedge.
- `issa` is a correction only next to a state verb; "kien" + imperfect covers a few verbs.
- Dual forms ("ġimagħtejn ilu") are read by splitting stem and ending: check the stems.
- Past forms are listed by person for about 35 verbs: check the loan verbs. "fit-3" and "l-1"
  match the engine's identifier pattern.

## Polish (pl)

- `może` alone is not speculation; `chyba`, `pewnie`, `kiedyś`, `teraz`/`obecnie` are kept but
  ambiguous. `poprawka` is a correction only as a heading.
- Future: `będzie` + verb and a fixed list of perfective futures. Negative imperatives are
  matched by ending; others are missed.
- `lata`/`lat` are year forms, so "zeszłego lata" (last summer) reads as last year.
- `jesteś teraz` fires on "Gdzie jesteś teraz?".

## Portuguese (pt)

- European and Brazilian forms are both covered ("planeia/planeja", "já não" and "não … mais",
  "utilizador/usuário").
- Events: any word in "-ou" except "estou", "-iu", "-aram/-eram/-iram" ("Moscou" and the present
  "esperam" match).
- The future "-ará/-erá/-irá" needs three letters before the ending; plural "-ão" is a verb list.
- Short weekday names ("segunda") need a preposition or "passada".
- `carteira` (wallet) is an injection target word and also an ordinary word.

## Romanian (ro)

- Patterns accept ș/ț, ş/ţ and no diacritics. Without diacritics "sa", "ca" and "va" collide
  with other words: `va` is a plan marker only before a listed verb.
- `nu` at the start marks an instruction; subject-dropped facts ("Nu are mașină") are misread.
- `luni` is Monday and "months"; `nouă` is nine, new and "to us".
- Past participles as event markers also match adjectives ("este căsătorit").
- A bare genitive ("este managerul Danei") is not read as a relationship.

## Slovak (sk)

- Told from Czech by `som`, `sú`, `sa`, `alebo`, `keď`, `ktorý`, `teraz`, `nie`, `aj` and the
  letters ä ľ ĺ ŕ ô.
- `asi` is left out of speculation; `rada` (also "advice", "council") is a preference only next
  to a verb; `oprava` only as a heading.
- "o + time" is a plan for days, weeks and months, not years.
- `teraz si` alone is not an injection phrase (`si` is also reflexive).

## Slovenian (sl)

- Future and past share the l-participle: `bo` + a word in -l/-la/-lo/-li/-le within three words
  is a plan, which over-matches ("bo v šoli").
- `mogoče` counts only as "mogoče, da"; "ne <verb> več" also catches "ne potrebuje več kot 5";
  `prej` only next to an auxiliary.
- `poročila`/`naročila` are also nouns; "married" needs `se`.
- Dual forms are included. Negative imperatives in -i (`ne piši`) are missed.

## Spanish (es)

- Events: any word in "-ó" and "-aron/-ieron" ("dominó", "Aaron" match); `vino` and `traje` are
  left out.
- The future is matched by accented endings; unaccented spellings are missed. `mañana` counts
  only in unambiguous contexts.
- `ahora` and "de hecho" are correction markers.
- An opening "No" + infinitive or a word in "-es/-as" reads as an instruction ("No todas las
  facturas…" is misread); "usted" imperatives are not covered.
- `once` (11) collides with English "once" when both packs are enabled.

## Swedish (sv)

- `ska` is a plan only before one of a list of action verbs (the list needs a look); `tänker`
  is a plan marker, "tänker på att" and "funderar på" speculation.
- `faktiskt` and `egentligen` are both correction markers.
- "i helgen" is not read as last weekend; `dog` (died) is left out.
