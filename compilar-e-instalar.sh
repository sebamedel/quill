#!/bin/sh
# Compila, firma e instala quill, y reinicia el daemon.
#
# El paso de firma es el que importa y no es cosmetico. Un binario de Swift sin
# firmar queda con firma "adhoc", y ahi macOS no identifica la app por quien la
# firmo sino por el hash del ejecutable:
#
#   adhoc    designated => cdhash H"f703..."
#   firmado  designated => identifier quill and certificate root = H"5d34..."
#
# Ese requisito designado es lo que TCC guarda al concederte microfono y captura
# de audio del sistema. Con firma adhoc cambia en cada compilacion, macOS cree
# que es una aplicacion nueva y vuelve a pedir todos los permisos desde cero.
# Firmando con una identidad estable, las versiones nuevas siguen siendo la
# misma app y los permisos se conservan.
#
# El certificado es autofirmado y local: no sirve para distribuir a nadie, solo
# para que tu propio Mac reconozca tus compilaciones. Si no existe, este script
# lo dice y sigue sin firmar, para no bloquear una compilacion de emergencia.
#
# Crear el certificado una sola vez, si hiciera falta en otro Mac:
#   openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 \
#     -nodes -subj "/CN=quill-dev" \
#     -addext "basicConstraints=critical,CA:false" \
#     -addext "keyUsage=critical,digitalSignature" \
#     -addext "extendedKeyUsage=critical,codeSigning"
#   openssl pkcs12 -export -out quill-dev.p12 -inkey key.pem -in cert.pem \
#     -passout pass:CLAVE -name quill-dev \
#     -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1
#   security import quill-dev.p12 -k ~/Library/Keychains/login.keychain-db \
#     -P CLAVE -T /usr/bin/codesign
#
# (Las opciones -certpbe/-keypbe/-macalg son necesarias: OpenSSL 3 empaqueta por
# defecto con un cifrado que la herramienta `security` de macOS rechaza.)

set -e

IDENTIDAD="quill-dev"
DESTINO="/opt/homebrew/bin/quill"
cd "$(dirname "$0")"

echo "compilando..."
swift build -c release

if security find-certificate -c "$IDENTIDAD" >/dev/null 2>&1; then
  codesign --force --sign "$IDENTIDAD" --identifier quill .build/release/quill
  echo "firmado con $IDENTIDAD"
else
  echo "aviso: no existe el certificado \"$IDENTIDAD\"; se instala sin firmar"
  echo "       macOS va a volver a pedir los permisos en cada compilacion"
fi

cp .build/release/quill "$DESTINO"
launchctl kickstart -k "gui/$(id -u)/com.digimata.quill"
echo "instalado en $DESTINO y daemon reiniciado"
