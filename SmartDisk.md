# Slimme schijf: conceptdocument

Oct 21, 2026 · @Jitse Lambrichts

## Het idee in één minuut

De Slimme schijf is een virtuele schijf voor macOS die je bestanden ordent op wat erin staat, zonder één bestand te verplaatsen of te kopiëren. Ze verschijnt in de Finder-zijbalk zoals een USB-stick, en dus ook in elk open- en bewaarvenster van elke app en in de terminal.

- **Mappen die zichzelf vullen:** Facturen, Contracten, ID-documenten, Thesis, Strandfoto's.
- **Eén bestand, meerdere plekken:** een factuur van je kot staat zowel in Facturen als in Wonen; het origineel blijft waar het was.
- **Een map maken is een zoekopdracht:** noem een nieuwe map "facturen 2026 boven 100 euro" en ze vult zich.
- **Alles lokaal:** geen bestand en geen tekst verlaat de Mac.

Voor wie: Mac-gebruikers met een overvolle Downloads-map, en developers en AI-agents die semantisch willen zoeken met gewone bestandscommando's.

De demo die het verhaal draagt:

```bash
mkdir "/Volumes/Slim/facturen 2026 boven 100 euro"
ls "/Volumes/Slim/facturen 2026 boven 100 euro"
```

In Finder werkt hetzelfde: nieuwe map, naam typen, en de map vult zich voor je ogen.

## Probleem en waarom nu

Mappen dwingen elk bestand op één plek, en zoeken op de Mac is te zwak om dat op te vangen. Sinds macOS 15.4 kan een gewone app daar voor het eerst een eigen bestandssysteem tegenover zetten.

**Het probleem**

- **Zoeken werkt niet goed genoeg.** Sommige gebruikers proberen Finder en Spotlight [niet eens meer](https://kaspars.net/note/mastodon-social-116443006958020963/md) omdat de resultaten zo slecht zijn.
- **Eén plek per bestand.** Een huurfactuur hoort bij Facturen én bij Wonen. Finder's [slimme mappen](https://zushapp.com/blog/finder-tags-guide-organize-files-mac) kunnen dat, maar filteren alleen op kenmerken zoals type, datum en tag, niet op wat er in het document staat.
- **AI-ordeners verplaatsen je bestanden.** [LlamaFS](https://www.sourcepulse.org/projects/1254971) hernoemt en verhuist bestanden op basis van inhoud. Dat voelt riskant: wie een fout ontdekt, moet zelf terugzoeken waar alles stond.

**Waarom nu**

1. **FSKit.** Sinds macOS 15.4 bouw je een [bestandssysteem dat in user space draait](https://developer.apple.com/tutorials/data/documentation/fskit.md), verpakt als app-extensie en zelfs via de Mac App Store te verspreiden. Vroeger kon dat alleen met een kernelextensie.
2. **Lokale AI is snel genoeg.** Tekstherkenning, embeddings en kleine taalmodellen draaien op Apple Silicon zonder cloud, dus gevoelige documenten blijven thuis.
3. **AI-agents werken met bestanden.** Een map die een zoekopdracht is, geeft elke agent semantische toegang met gewone commando's zoals `ls` en `cat`, zonder extra integratie.

## Hoe het werkt voor gebruikers

Dezelfde schijf bedient twee groepen: gewone gebruikers klikken erin in Finder, developers en agents gebruiken exact dezelfde paden in de terminal.

| Wie | Situatie | Wat ze doen op de Slimme schijf |
| --- | --- | --- |
| Student | Een website vraagt een kopie van je identiteitskaart | In het uploadvenster: Slim → ID-documenten → kiezen. Geen zoektocht door Downloads. |
| Huurder | Discussie met de verhuurder over de waarborg | Map Wonen bevat huurcontract, plaatsbeschrijving en betalingsbewijzen, ook al staan die verspreid over Mail-bijlagen en Documenten. |
| Iedereen in mei | Belastingaangifte invullen | Nieuwe map "belastingen 2025" verzamelt fiscale fiches, attesten en giftbewijzen. |
| Developer | Facturen doorsturen naar de boekhouder | `cp "/Volumes/Slim/facturen 2026 boven 100 euro"/* ~/boekhouding/` |
| AI-agent | "Welke contracten hebben een opzegtermijn langer dan een maand?" | De agent doet `ls "/Volumes/Slim/contracten met opzegtermijn"` en leest de resultaten met `cat`, zonder extra koppeling. |

Naast de schijf komt een klein menubalk-icoon voor status (hoeveel bestanden geïndexeerd, wat er bezig is) en een CLI voor wie scripts schrijft:

```bash
slim query "huurcontract" --json
slim why "/Volumes/Slim/Facturen/factuur-0423.pdf"
```

`slim why` toont waarom een bestand in een map staat: de gevonden tekst, de datum en de score. Dat maakt fouten begrijpelijk en herstelbaar.

## Wat al bestaat en positionering

Geen bestaand project combineert de drie dingen tegelijk: macOS-native als schijf, gebaseerd op inhoud, en zonder bestanden te verplaatsen.

| Project | Platform | Wat het doet | Wat ontbreekt |
| --- | --- | --- | --- |
| [Finder slimme mappen en tags](https://zushapp.com/blog/finder-tags-guide-organize-files-mac) | macOS | Virtuele verzamelingen zonder te verplaatsen | Filtert alleen op type, datum en tags; geen inhoud, niet als gewone map in de terminal |
| [LlamaFS](https://www.sourcepulse.org/projects/1254971) | macOS, Linux | AI hernoemt en verplaatst bestanden op inhoud | Destructief; groei is stilgevallen |
| [TagSpaces](https://www.makeuseof.com/better-way-to-organize-files-tagspaces/) | Desktop-app | Tags, voorbeelden en zoeken bovenop bestaande mappen | Eigen app, geen schijf; tags handmatig |
| [Tagsistant, TMSU](https://en.wikipedia.org/wiki/Semantic_file_system) | Linux (FUSE) | Tag-gebaseerde virtuele mappen | Geen AI, geen macOS-integratie |
| [OrgFs](https://github.com/harshadjs/orgfs) | Linux (FUSE) | Zoekmappen maken met mkdir | Alleen voor Org-mode-notities |
| [SemanticFS](https://github.com/Navneeth08k/semanticFS) | Linux; macOS via MCP | Semantisch zoeken in code voor agents | Virtuele schijf alleen op Linux; gericht op code, niet op documenten |
| [Spacedrive](https://v2.spacedrive.com/) | Cross-platform | Eigen bestandsbeheerder met inhoudsindex | Eigen app in alpha; verschijnt niet in open- en bewaarvensters |

Het idee zelf is niet nieuw: al in 1991 stelde MIT voor om [mapnamen als zoekopdrachten](https://dl.acm.org/doi/10.1145/121133.121138) te behandelen. Nieuw is dat het nu native op de Mac kan, met lokale AI die begrijpt wat er in een PDF of foto staat.

**Positionering in één zin:** de Slimme schijf is geen nieuwe bestandsbeheerder, maar een laag onder Finder die overal verschijnt waar je een bestand kiest.

## Gedragsregels van de schijf

De gouden regel: niets wat je op de Slimme schijf doet, kan een origineel bestand beschadigen of wissen. De schijf toont alleen weergaven; acties veranderen labels, nooit bestanden.

| Actie in Finder of terminal | Wat er echt gebeurt | Versie |
| --- | --- | --- |
| Bestand openen of kopiëren | Leest het origineel rechtstreeks, zonder kopie | v0.1 |
| Bestand naar elders slepen | Kopie naar de bestemming, zoals tussen twee schijven gebruikelijk | v0.1 |
| Nieuwe map maken | De mapnaam wordt een bewaarde zoekopdracht; de map vult zich | v0.2 |
| Map hernoemen | De zoekopdracht verandert; de inhoud wordt opnieuw berekend | v0.2 |
| Map verwijderen | Alleen de zoekopdracht verdwijnt; geen enkel bestand | v0.2 |
| Bestand uit een map verwijderen | "Hoort hier niet": het bestand verdwijnt uit die weergave, het origineel blijft | v0.3 |
| Bestand in een map slepen | "Hoort hier wel": een label dat de categorie bijleert | v0.3 |
| Bestand bewerken en bewaren | Schrijft door naar het origineel | v0.4 |
| Nieuw bestand bewaren in de schijf | Komt in een echte map Slim-inbox in Documenten en krijgt meteen labels | v0.4 |

**Structuur van de schijf**

- Bovenaan staan de automatische categorieën (Facturen, Contracten, ID-documenten, Foto's, Screenshots) en de zoekmappen die je zelf maakte, naast elkaar.
- Twee bestanden met dezelfde naam in één map krijgen hun herkomst erbij, bijvoorbeeld `factuur (Downloads).pdf` en `factuur (Mail).pdf`.
- Een verborgen map `.slim` bevat de status, de logboeken en de uitleg per bestand voor scripts.

**Waarom eerst alleen-lezen:** veel apps bewaren via een tijdelijk bestand dat daarna over het origineel wordt hernoemd. Op een virtuele map is dat lastig correct te vertalen, dus schrijven komt pas als het grondig getest is.

## Technische architectuur

Bouw één Rust-kern die alles weet, met twee dunne lagen die haar als schijf tonen: eerst FUSE om snel te testen, daarna een native FSKit-extensie zodat gewone gebruikers maar één app installeren.

&#91;embedded content: architectuur · drie lagen boven één Rust-kern\]

Finder, terminal en agents zien allemaal dezelfde schijf; welke backend eronder zit, merken ze niet. De kern leest je originelen maar schrijft er nooit in.

**Hoe macOS je een schijf laat maken**

| Optie | macOS | Voordeel | Nadeel |
| --- | --- | --- | --- |
| [FSKit](https://developer.apple.com/tutorials/data/documentation/fskit.md) rechtstreeks | Basis vanaf 15.4; [padbronnen](https://developer.apple.com/documentation/fskit/fspathurlresource.md) pas vanaf 26.0 | Niets extra te installeren, via de App Store te verspreiden | Jong: Apple ondersteunt voorlopig alleen de eenvoudige FSUnaryFileSystem-vorm, documentatie is mager |
| [macFUSE 5](https://newreleases.io/project/github/macfuse/macfuse/release/macfuse-5.0.0) met FSKit-backend | 15.4+ via FSKit, ouder via kernelextensie | Standaard FUSE-code, dezelfde Rust-crate werkt op Linux | Gebruiker moet macFUSE apart installeren |
| [FUSE-T](https://github.com/macos-fuse-t/fuse-t) | Ook oudere versies | Geen kernelextensie: vertaalt FUSE naar een lokale NFS-server | Aparte installatie; de prullenmand van Finder werkt [niet op zulke schijven](https://github.com/gqf2008/ossfs) |
| File Provider | 11+ | Goed geïntegreerd, gemaakt voor iCloud en Dropbox | Maakt lokale kopieën van wat je opent: dubbele opslag voor bestanden die al lokaal staan |

**Keuze**

1. **Prototype (v0.1 tot v0.3) op FUSE** met de Rust-crate `fuser`, via macFUSE of FUSE-T. Snelste manier om het gedrag te testen, en het werkt meteen ook op Linux.
2. **Eindproduct (v1.0) als FSKit-extensie** met een padbron, dus macOS 26 of nieuwer. Apple levert daarvoor zelf een [passthrough-voorbeeld](https://developer.apple.com/documentation/fskit/building-a-passthrough-file-system.md) dat een bestaande map als nieuwe schijf toont.
3. **Brug tussen Swift en Rust:** [fskit-rs](https://crates.io/crates/fskit-rs) laat de Swift-extensie via lokale berichten met een Rust-kern praten; alternatief is een eigen XPC-koppeling.

Beide backends implementeren één Rust-trait, bijvoorbeeld `VirtualVolume` met `lookup`, `readdir`, `getattr`, `read` en `mkdir`. Bestandsinhoud gaat rechtstreeks van het origineel naar de lezer; de index slaat alleen tekst en vectoren op.

**Datamodel in SQLite**

| Tabel | Inhoud |
| --- | --- |
| `files` | id, pad, grootte, wijzigingsdatum, inhoudshash |
| `chunks` | file\_id, tekstfragment, embedding |
| `labels` | file\_id, categorie, bron (automatisch, gebruiker ja, gebruiker nee), zekerheid |
| `views` | id, mapnaam, geparste zoekopdracht, aanmaakdatum |
| `view_items` | view\_id, file\_id (cache, herberekend bij wijzigingen) |

## AI-pijplijn

Alles draait op de Mac met bouwstenen die al bestaan: Apple's eigen tekstherkenning, een klein open embedding-model en Apple's ingebouwde taalmodel om mapnamen te lezen. Harde feiten zoals datums en bedragen komen uit gewone code, nooit uit een model.

**Van bestand naar categorie**

1. **Opmerken.** De bestandswachter volgt de mappen die de gebruiker koos. Bestanden in iCloud die niet lokaal staan, worden overgeslagen tot ze gedownload zijn, zodat indexeren nooit een download start.
2. **Tekst halen.** PDF's met tekstlaag direct; scans, foto's en screenshots via Apple Vision, dat [onder macOS 26 ook Nederlands herkent](https://pypi.org/project/ocrmypdf-appleocr/); Word- en Pages-bestanden via de systeemconverters.
3. **Feiten halen met code.** Datums, bedragen in euro, btw-nummers en afzenders komen uit regels en patronen. Zelfde principe als [deze tool voor Zwitserse brieven](https://dev.to/damiano_builds/let-the-model-explain-let-the-code-count-a-local-llm-helper-for-swiss-administrative-letters-54je): het model legt uit, de code telt.
4. **Embeddings maken.** [EmbeddingGemma](https://huggingface.co/blog/embeddinggemma) (308 miljoen parameters, meer dan 100 talen, minder dan 200 MB geheugen gekwantiseerd) draait via ONNX in de Rust-kern.
5. **Categorie toekennen.** Een bestand komt in een categorie als de gelijkenis met de categoriebeschrijving hoog genoeg is én de regels kloppen (een factuur heeft een bedrag en een datum). Correcties van de gebruiker wegen het zwaarst.

Bij twijfel blijft een bestand buiten de map. Een ontbrekend bestand is minder erg dan een verkeerd bestand, want vertrouwen is het hele product.

**Van mapnaam naar zoekopdracht**

Apple's [Foundation Models-framework](https://www.cultofmac.com/news/apple-foundation-models-framework) geeft apps op macOS 26 toegang tot het lokale taalmodel van Apple Intelligence, met gestructureerde uitvoer. Daarmee wordt een mapnaam omgezet naar velden:

```json
{
  "categorie": "factuur",
  "jaar": 2026,
  "bedrag_min": 100,
  "valuta": "EUR",
  "vrije_tekst": null
}
```

Wat niet in een veld past, gaat naar `vrije_tekst` en wordt semantisch gezocht. Staat Apple Intelligence uit of ontbreekt het, dan valt de kern terug op een eenvoudige parser met trefwoorden plus puur semantisch zoeken.

**Mapnamen die moeten werken in versie 1**

- `facturen 2026 boven 100 euro`
- `contracten met opzegtermijn`
- `alles over mijn kot`
- `screenshots met een code erin`
- `pdf van school deze maand`

## Privacy en veiligheid

Het grootste veiligheidsrisico is niet de AI maar de schijf zelf: ze mag geen achterdeur worden langs de privacybescherming van macOS. Dat moet getest zijn vóór de eerste publieke release.

**Het probleem met privacyrechten**

macOS laat apps niet zomaar in Documenten, Downloads of het Bureaublad kijken: de eerste keer volgt een [toestemmingsvraag](https://eclecticlight.co/2026/04/07/privacy-protected-folders/). Ook verwijderbare en netwerkschijven zijn beschermd, maar [niet elke verwijderbare schijf wordt zo behandeld](https://eclecticlight.co/2026/04/15/privacy-which-folders-are-protected-in-tahoe/). Toont de Slimme schijf je ID-scan uit Documenten op /Volumes/Slim zonder die bescherming, dan kan elke app hem lezen zonder vraag.

**Maatregelen**

- **Testen welke bescherming de schijf krijgt** onder FUSE-T (gezien als netwerkschijf), macFUSE en FSKit, en het resultaat publiek documenteren.
- **Gevoelige categorieën standaard uit:** ID-documenten, medische en financiële papieren verschijnen pas na expliciete toestemming.
- **Alleen de eigenaar mag lezen:** de schijf wordt gekoppeld met rechten die enkel de ingelogde gebruiker toelaten.
- **Mappen kiezen in plaats van alles:** de gebruiker selecteert welke mappen geïndexeerd worden, via de gewone kiezer van macOS.

**De index is zelf gevoelig**

- De index bevat tekst uit al je documenten en is dus een aantrekkelijk doelwit. Hij staat in de container van de app, beschermd door FileVault.
- Ook embeddings zijn niet onschuldig: uit vectoren kan soms tekst gereconstrueerd worden. Een optie bewaart enkel vectoren en velden, geen volledige tekst.
- Geen telemetrie, geen netwerkverkeer behalve het eenmalig downloaden van het model, en dat staat zo in de README.

**AI-agents**

Agents die op de schijf lezen, krijgen documenten te zien die verborgen instructies kunnen bevatten. De schijf filtert dat niet, maar de README raadt aan agents enkel toegang te geven tot specifieke zoekmappen in plaats van tot de hele schijf.

## Risico's en open vragen

Het grootste technische risico is FSKit zelf: het is jong, en anderen zijn er al op vastgelopen. Daarom start het prototype op FUSE en blijft de backend vervangbaar.

| Risico | Waarom het speelt | Aanpak |
| --- | --- | --- |
| FSKit-bugs blokkeren de release | Een ander project kreeg zelfs [Apple's eigen passthrough-voorbeeld niet ingeschakeld](https://azimi.me/git-lazy-mount/future-platforms/macos/) op macOS 26.4.1; [ExtendFS](https://github.com/kthchew/ExtendFS) meldt bugs en vertraging door FSKit | FUSE-prototype eerst; FSKit per macOS-update opnieuw testen |
| Finder toont verouderde mappen | FSKit gaat er [voorlopig van uit](https://github.com/cryptomator/cryptomator/issues/3583) dat niemand buiten het bestandssysteem om wijzigt, terwijl onze mappen voortdurend veranderen | Vroeg testen hoe snel Finder vernieuwt; bij FUSE de kernel expliciet laten weten wat veranderde |
| Configuratie doorgeven aan de extensie | Gedeelde app-groepen en sleutelhanger [werken niet](https://github.com/indragiek/GHFS/blob/main/FSKIT.md) voor FSKit-extensies op macOS 26.4 | Configuratie in een map van de hoofdapp zetten en die als padbron koppelen, zoals GHFS documenteert |
| Opslaan breekt bestanden | Apps bewaren vaak via een tijdelijk bestand en hernoemen het daarna | Alleen-lezen tot schrijven getest is met Voorvertoning, Pages, Word en VS Code |
| Verwijderen in Finder verwart | Op NFS-schijven zoals bij FUSE-T [werkt de prullenmand niet](https://github.com/gqf2008/ossfs) | Verwijderen vertalen naar "uit deze map halen" en dat duidelijk tonen |
| Foute categorieën | Eén verkeerde ID-scan in Facturen kost vertrouwen | Liever te weinig dan fout, `slim why`, één sleepbeweging om te corrigeren |
| Eerste indexering is traag | Duizenden PDF's en foto's door OCR en embeddings halen kost tijd en batterij | Op de achtergrond met lage prioriteit, pauzeren op batterij, recente bestanden eerst |
| Geen Apple Intelligence | Het taalmodel werkt alleen op [geschikte toestellen met Apple Intelligence aan](https://www.cultofmac.com/news/apple-foundation-models-framework) | Eenvoudige parser plus semantisch zoeken als terugval |
| Distributie | De extensie vraagt een [FSKit-entitlement](https://github.com/indragiek/GHFS/blob/main/FSKIT.md) en moet na elke build opnieuw ingeschakeld worden in Systeeminstellingen | Apple Developer-account, notarisatie, installeren via Homebrew en een .dmg |

**Beslissingen die nog open liggen**

- Minimumversie: alleen macOS 26 en nieuwer (eenvoudiger, FSKit met padbronnen), of ook 15 via FUSE?
- Licentie: MIT of Apache-2.0 voor maximale adoptie, of GPL zodat verbeteringen open blijven?
- Welke mappen standaard aanstaan: alleen Downloads en Documenten, of ook Bureaublad en Mail-bijlagen?
- Definitieve naam (zie Lancering).

## Roadmap

Bouw eerst een alleen-lezen prototype dat op je eigen Mac werkt, en ga pas naar de volgende versie als de poort ervoor gehaald is. Schrijven en FSKit komen bewust als laatste, omdat daar de grootste risico's zitten.

&#91;embedded content: roadmap · vijf versies, vier poorten\]

Elke poort is een test die je zelf kunt doen; pas als die slaagt, komt er nieuwe functionaliteit bij.

**Afvinklijst voor v0.1**

- [ ] Rust-workspace met de crates `core`, `fs-fuse` en `cli`
- [ ] Bestandswachter op Downloads en Documenten
- [ ] Tekst uit PDF's halen, plus OCR via Apple Vision
- [ ] EmbeddingGemma via ONNX, vectoren opgeslagen in SQLite
- [ ] Vier categorieën: Facturen, Contracten, ID-documenten, Screenshots
- [ ] Alleen-lezen schijf via `fuser`, getest in Finder en de terminal
- [ ] `slim why` voor elk bestand
- [ ] Testset van 100 eigen bestanden met juiste labels, om de categorieën te meten

## Lancering en groei

Lanceer twee keer: eerst een technisch verhaal over FSKit voor developers, daarna een Show HN zodra iedereen het in één stap kan installeren. De schaarse FSKit-documentatie maakt dat eerste verhaal waardevol, en dat brengt de eerste sterren.

**Naam en slogan**

- "Slim" werkt in het Nederlands, maar betekent in het Engels "dun". Voor een internationaal publiek: kandidaten als Facet, Sift of Shelf, na controle op GitHub, Homebrew en domeinnamen.
- Slogan: *Folders that fill themselves. mkdir is a search query.*

**README, in deze volgorde**

1. Een GIF van drie seconden: in Finder een nieuwe map "invoices 2026 over 100 euro" maken, en ze vult zich.
2. Installatie in één regel, bijvoorbeeld `brew install --cask <naam>`.
3. Drie beloftes: je bestanden worden nooit verplaatst, alles blijft op je Mac, geen account.
4. Het architectuurschema en een korte uitleg.
5. Veelgestelde vragen: verplaatst het mijn bestanden, wat gebeurt er als ik verwijder, welke macOS-versie.

**Show HN volgens de regels**

De [Show HN-richtlijnen](https://news.ycombinator.com/showhn.html) zijn strikt, dus pas posten als alles klopt:

- Het moet iets zijn dat mensen zelf kunnen proberen, zonder aanmelding of e-mail; een landingspagina telt niet.
- Het project moet substantieel zijn: snel gegenereerde eenmalige projecten zijn niet welkom. Vertel waarom je het bouwde.
- Vraag vrienden niet om te upvoten of te reageren.
- Een feitelijke titel, bijvoorbeeld: *Show HN: A macOS file system where mkdir is a search query*.

**Andere kanalen**

- Het technische verhaal ("Wat ik leerde door een bestandssysteem te bouwen met FSKit") als gewone HN-post en op je blog.
- Een `FSKIT.md` met praktijknotities in de repo; developers die FSKit-hulp zoeken, vinden zo je project.
- r/macapps en r/MacOS, Product Hunt in de Mac-categorie, en Mac-blogs die FSKit al volgen, zoals [The Eclectic Light Company](https://eclecticlight.co/2025/11/18/which-local-file-systems-does-macos-26-support/).

## Bronnen

**macOS en FSKit**

- [FSKit, Apple-documentatie](https://developer.apple.com/tutorials/data/documentation/fskit.md)
- [FSPathURLResource, Apple-documentatie](https://developer.apple.com/documentation/fskit/fspathurlresource.md)
- [Building a passthrough file system, Apple](https://developer.apple.com/documentation/fskit/building-a-passthrough-file-system.md)
- [GHFS: FSKit-praktijknotities](https://github.com/indragiek/GHFS/blob/main/FSKIT.md)
- [ExtendFS: ext4 via FSKit](https://github.com/kthchew/ExtendFS)
- [git-lazy-mount: waarom macOS niet lukte](https://azimi.me/git-lazy-mount/future-platforms/macos/)
- [Cryptomator-discussie over FSKit](https://github.com/cryptomator/cryptomator/issues/3583)
- [fskit-rs](https://crates.io/crates/fskit-rs)
- [macFUSE 5.0 release notes](https://newreleases.io/project/github/macfuse/macfuse/release/macfuse-5.0.0)
- [FUSE-T](https://github.com/macos-fuse-t/fuse-t)
- [OSSFS: prullenmand op NFS-schijven](https://github.com/gqf2008/ossfs)
- [Which local file systems does macOS 26 support?](https://eclecticlight.co/2025/11/18/which-local-file-systems-does-macos-26-support/)

**Privacy**

- [Privacy: protected folders](https://eclecticlight.co/2026/04/07/privacy-protected-folders/)
- [Privacy: Which folders are protected in Tahoe?](https://eclecticlight.co/2026/04/15/privacy-which-folders-are-protected-in-tahoe/)

**AI-bouwstenen**

- [Apple Foundation Models-framework](https://www.cultofmac.com/news/apple-foundation-models-framework)
- [EmbeddingGemma](https://huggingface.co/blog/embeddinggemma)
- [OCRmyPDF AppleOCR: ondersteunde talen](https://pypi.org/project/ocrmypdf-appleocr/)
- [Let the model explain, let the code count](https://dev.to/damiano_builds/let-the-model-explain-let-the-code-count-a-local-llm-helper-for-swiss-administrative-letters-54je)

**Bestaande projecten en context**

- [Finder-tags en slimme mappen](https://zushapp.com/blog/finder-tags-guide-organize-files-mac)
- [LlamaFS op SourcePulse](https://www.sourcepulse.org/projects/1254971)
- [TagSpaces](https://www.makeuseof.com/better-way-to-organize-files-tagspaces/)
- [Semantic file system, Wikipedia](https://en.wikipedia.org/wiki/Semantic_file_system)
- [Semantic file systems, SOSP 1991](https://dl.acm.org/doi/10.1145/121133.121138)
- [OrgFs](https://github.com/harshadjs/orgfs)
- [SemanticFS](https://github.com/Navneeth08k/semanticFS)
- [Spacedrive v2](https://v2.spacedrive.com/)
- [Klacht over zoeken op macOS](https://kaspars.net/note/mastodon-social-116443006958020963/md)
- [Show HN-richtlijnen](https://news.ycombinator.com/showhn.html)
