# ShyzosWinFixer

Petites réparations Windows en une seule commande. Pour l'instant, il y a une fonction : **vider la RAM sans fermer aucun programme**.

## Lancer

Ouvre PowerShell (de préférence **en administrateur** : clic droit sur Démarrer → *Terminal (administrateur)*) et colle :

```powershell
irm https://raw.githubusercontent.com/ShyzosCorp/ShyzosWinFixer/main/ShyzosWinFixer.ps1 | iex
```

Si le terminal n'est pas en admin, le script se relance tout seul dans une fenêtre admin : Windows te demande juste de confirmer (UAC).

Rien n'est installé. Le script marche avec le PowerShell intégré à Windows (5.1) et avec PowerShell 7.

> Avant de lancer un script trouvé sur Internet, lis-le. Celui-ci tient dans un seul fichier : [`ShyzosWinFixer.ps1`](ShyzosWinFixer.ps1).

## Ce que ça fait

1. **Réduit la mémoire de tous les processus.** Il utilise la même fonction de Windows que `RAMMap -Ew` (Microsoft Sysinternals). Ce que les programmes gardaient en RAM « au cas où » passe en cache ou dans le fichier d'échange.
2. **Vide le cache disque de WSL** si une distribution Linux tourne. Tes services et tes conteneurs Docker ne sont pas arrêtés.
3. **Affiche le résultat** : RAM avant / après et Go libérés.

Aucun programme n'est fermé, aucun fichier n'est supprimé et aucun réglage n'est modifié.

## L'affichage

Quand la console le permet, le script affiche une petite animation : le logo apparaît en dégradé vert → rouge, chaque étape s'affiche avec un indicateur (`[ OK ]`, `[WARN]`, `[FAIL]`), puis un résultat avec la RAM avant / après, les Go libérés et la durée.

Rien n'est enregistré sur le disque et rien n'est envoyé nulle part.

Dans Windows Terminal, le script utilise des symboles plus jolis (⠋ ⚠ ►). Dans la console classique, il prend des symboles simples qu'elle sait afficher. Si la sortie est redirigée vers un fichier, ou avec `-Plain`, tout passe en texte simple.

## Options

En téléchargeant le script ou en clonant le repo :

```powershell
.\ShyzosWinFixer.ps1            # vidage standard
.\ShyzosWinFixer.ps1 -Standby   # vide aussi le cache en attente (standby)
.\ShyzosWinFixer.ps1 -NoWsl     # ne touche pas à WSL
.\ShyzosWinFixer.ps1 -Plain     # sans animation (texte simple)
```

Avec la commande en une ligne :

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/ShyzosCorp/ShyzosWinFixer/main/ShyzosWinFixer.ps1))) -Standby
```

## À savoir

- **C'est temporaire.** Chaque programme recharge ce dont il a besoin au moment où il s'en sert, donc la RAM remonte petit à petit. C'est normal.
- **Évite de le lancer en pleine partie** : le jeu peut laguer quelques secondes, le temps de recharger. Le script te prévient s'il détecte un jeu.
- **`-Standby` est rarement utile.** Le cache en attente compte déjà comme de la RAM disponible, et Windows le libère tout seul quand un programme en a besoin.
- Si ta RAM est haute même au repos, cherche ce qui la mange (Gestionnaire des tâches → *Processus*, tri par *Mémoire*). Si tu utilises WSL ou Docker, tu peux limiter et rendre la RAM de WSL avec un fichier `%UserProfile%\.wslconfig` :

  ```ini
  [wsl2]
  memory=8GB

  [experimental]
  autoMemoryReclaim=gradual
  ```

  Puis lance `wsl --shutdown`.

## Licence

MIT
