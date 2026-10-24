# LiDAR Studio 3D — progetto SwiftUI + RoomPlan

Versione iniziale **0.1**: acquisisce la geometria di una stanza con il LiDAR di un iPhone compatibile, mostra l'anteprima 3D ed esporta in USDZ.

## Sviluppo esclusivamente da iPhone (prima fase gratuita)

1. Da Safari crea un account GitHub e un repository **pubblico** chiamato `LiDARStudio3D`, inizializzando un README.
2. Carica `LiDARStudio3D_START_iPhone.zip` nella radice del repository (Add file > Upload files > Commit changes).
3. Crea un file `.github/workflows/avvio-ios.yml` e incolla il contenuto del file `avvio-ios.yml` fornito separatamente da ChatGPT.
4. Vai nella scheda Actions. Il workflow estrae automaticamente il progetto Swift nel repository, esegue una build iOS Simulator senza firma e mostra se compila.
5. Per modifiche successive, apri i file Swift direttamente nella scheda Code, premi Edit e conferma il commit. Ogni commit farà ripartire la compilazione.

GitHub Actions su repository **pubblici** con runner standard sono gratuiti. Il codice sarà visibile a tutti. Non caricare password, certificati o scansioni private. La build è **solo una verifica**, non crea un'app installabile su iPhone e non esegue il LiDAR.

## Stato

- Ambiente: SwiftUI, RoomPlan, iOS 17+
- Scanner ambienti: implementazione iniziale da verificare con compilazione reale.
- Modifica mesh avanzata: non ancora presente.
- App su iPhone: richiederà un successivo percorso di firma/installazione iOS. TestFlight richiede Apple Developer Program, mentre un account gratuito consente test da Xcode su Mac con restrizioni.

Riferimenti:
- https://developer.apple.com/documentation/roomplan
- https://docs.github.com/en/actions/reference/runners/github-hosted-runners
- https://developer.apple.com/it/help/account/basics/about-your-developer-account
