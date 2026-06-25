# l-mirror (reserve froide, chiffree)

Miroir de secours de l'ecosysteme (repo prive bennisboss-gif/l). 3e cran de la redondance multi-canal.
RECUPERABLE SANS TOKEN (repo public) ; le contenu est chiffre AES-256, la passphrase vit en memoire (jamais ici).

## Recovery
1. telecharger le .bin sous snapshots/ (pointeur = LATEST.json, champ 'bin')
2. verifier sha256(.bin)
3. openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:<PASSPHRASE memoire> -in <fichier>.bin -out l.tar.gz
4. tar xzf l.tar.gz  => repo complet (hors .git)

Autorite : le repo prive bennisboss-gif/l est la REFERENCE. Ce miroir = copie verifiee, jamais source de verite.
Rafraichi a chaque bascule/flush importante.
