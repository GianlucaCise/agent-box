# agent-box

Esegui un agente di programmazione ([pi](https://www.npmjs.com/package/@earendil-works/pi-coding-agent), [OpenCode](https://opencode.ai) o [dsh](https://www.npmjs.com/package/@deepseek-ai/dsh)) con un modello locale, dentro un container dove **ogni connessione di rete deve essere approvata da te**.
Ogni richiesta compare in un popup di [OpenSnitch](https://github.com/evilsocket/opensnitch) che mostra il processo vero (`curl`, `node`, …), i suoi argomenti e la destinazione.
L'unica eccezione è il server del modello, sulla porta che indichi tu.

Nato dal video di morrolinux sul comportamento di Qwen3.8-Flash-Next documentato da Cohere: [analisi](https://cohere.com/blog/concerning-behaviour-popular-open-weight-ai-model).

## Requisiti

- Linux con un desktop **Wayland**
- **podman** 5+ (rootless) e **podman-compose**
- un server del modello compatibile OpenAI su `127.0.0.1` (llama.cpp, ollama, LM Studio, vLLM…)

Sull'host non va installato nient'altro: l'interfaccia di OpenSnitch gira anch'essa in un container.

## Uso

```sh
git clone <questo repo> ~/agent-box
ln -s ~/agent-box/agent-box ~/.local/bin/agent-box   # facoltativo

export MODEL_ID=nome-del-modello   # come lo chiama il tuo server
export MODEL_PORT=8080             # porta del server su 127.0.0.1 (ollama: 11434, LM Studio: 1234)

cd ~/un-progetto
agent-box            # avvia pi nella cartella corrente
agent-box opencode   # oppure OpenCode
agent-box dsh        # oppure dsh, con l'interfaccia dsh-tui
agent-box dsh dshline                     # dsh con l'interfaccia dshline
agent-box dsh headless "sistema i test"   # dsh senza interfaccia: un compito e poi esce
agent-box bash       # una shell nella stessa scatola, per provare (es. `curl https://example.com`)
```

Al primo avvio vengono scaricate le due immagini da `ghcr.io/morrolinux` (circa 3 GB in tutto).
Se il download non riesce, vengono costruite in locale dal `Containerfile`: servono alcuni minuti.
Le immagini sono firmate con cosign, puoi verificarle con:

```sh
cosign verify ghcr.io/morrolinux/agent-box:latest \
  --certificate-identity-regexp '^https://github.com/morrolinux/agent-box/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

Per costruirle sempre in locale: `podman-compose -f ~/agent-box/compose.yaml build`.
Per chiudere l'interfaccia dei popup: `podman-compose -f ~/agent-box/compose.yaml down`.

Altre variabili:
- `MODEL_API_KEY`, se il server la richiede;
- `MODEL_CONTEXT`: contesto del modello in token, default 32768;
- `DSH_TUI_LANG`: lingua di dsh-tui, `en` (predefinita qui) o `zh`;
- `ALLOW_DNS=1`: le query DNS passano senza popup.
  È più comodo, ma il DNS può servire a far uscire piccole quantità di dati: lascialo spento se vuoi vedere tutto.

I popup, se non rispondi entro 30 secondi, negano la connessione. La durata predefinita è "una volta".
Le risposte "sempre" vengono salvate e valgono anche ai prossimi avvii.
Per azzerarle: `podman volume rm agent-box_rules`.

All'avvio pi e OpenCode non cercano aggiornamenti e non scaricano l'elenco dei modelli: nessun popup finché l'agente non fa qualcosa.
In dsh è spenta la telemetria (`DSH_TELEMETRY_DISABLED=1`): un feedback inviato dall'interfaccia non carica la sessione sui server di DeepSeek.
dsh-tui e dshline sono plugin di terze parti.
dsh-tui cerca aggiornamenti su npm a ogni avvio, senza un'opzione per evitarlo: nell'immagine questo controllo è tolto.

Una sola scatola alla volta: tutte condividono la rete dell'interfaccia, e una seconda si rifiuta di partire.

La cartella corrente è montata nella scatola **allo stesso percorso** ed è l'unica parte del tuo disco che l'agente vede.
Viene rietichettata per SELinux (`:z`), per questo `agent-box` si rifiuta di partire da `/`, dalle cartelle di sistema, dalla home, dalle cartelle che la contengono e dalle sue cartelle nascoste.

## Come funziona

Due container che condividono la rete:

- **`ui`**: l'interfaccia di OpenSnitch. È l'unica con accesso al tuo schermo e non vede né i file né i processi dell'agente.
- **`agent`**: avvia il demone OpenSnitch come root. Il demone mette in coda ogni nuova connessione e chiede all'interfaccia. Poi l'agente parte come il tuo utente, senza alcun privilegio (nessuna capability, `no_new_privs`).

Garanzie:
- se il demone non sta filtrando, l'agente non parte;
- se il demone muore, non esce più niente;
- se il demone si blocca (con OpenSnitch 1.8.0 capita dopo un popup), dopo 5 secondi viene riavviato, e finché non è di nuovo pronto non esce niente. Lo stato delle sue goroutine al momento del blocco finisce in `/var/log/opensnitchd.stderr` nella scatola;
- l'agente non può modificare il firewall, né fermare o ispezionare il demone, né scrivere regole;
- svuotare l'ambiente (`env -i`) o creare namespace (`unshare`) non serve per aggirarlo.

## Limiti

- **Il kernel è quello dell'host.** Servono i moduli `nft_queue` e `nfnetlink_queue`, standard in tutte le distribuzioni. Se non vengono caricati da soli: `sudo modprobe nft_queue nfnetlink_queue`.
- **Non è una macchina virtuale.** Non protegge da exploit del kernel.
- **Ogni nuovo nome dà due popup**, a meno di `ALLOW_DNS=1`: prima la query DNS (che mostra già il nome), poi la connessione.
- **La porta dell'interfaccia è raggiungibile dall'agente.** L'agente può collegarsi e fingersi un altro demone: comparirebbe solo come nodo in più, senza poter approvare le proprie richieste.
- **Provato su Fedora/Bazzite** (SELinux, podman 5.8). Su altre distribuzioni e con X11 non è ancora stato provato.

## Licenza

MIT, vedi [LICENSE](LICENSE). OpenSnitch, pi, OpenCode, dsh, dsh-tui e dshline, installati nelle immagini, hanno le loro licenze.
