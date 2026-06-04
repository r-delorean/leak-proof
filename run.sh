#!/usr/bin/env bash
#
# Prova reprodutível: a tabela `is_risky_pattern` da submissão do bmtec
# (https://github.com/bmtec/rinha-backend-2026) foi calibrada nos payloads do
# `test-data.json` oficial — conserta 100% dos erros NO teste e ~7% FORA dele.
#
# Este script NÃO embute nada: ele clona o código do próprio bmtec num commit
# fixo, constrói o índice IVF do zero com o builder DELES a partir das
# referências públicas DELES, e só então roda o avaliador. Tudo acontece na
# sua frente — nenhum .bin pré-gerado, nenhum índice de origem desconhecida.
#
# Uso:
#   ./run.sh [caminho/para/test-data.json]
#
# O test-data.json é o oficial da Rinha (não é do bmtec, não vem aqui):
#   github.com/zanfranceschi/rinha-de-backend-2026  ->  test/test-data.json
#
set -euo pipefail

# --- Commit fixo do repo do bmtec (HEAD em 2026-06-04). Mude aqui se quiser
#     auditar outra revisão. ---
COMMIT="0e80820d6664ca744e45f8896650faf44caccb3c"
UPSTREAM="https://github.com/bmtec/rinha-backend-2026"
CENTROIDS="${CENTROIDS:-2048}"   # = ARG CENTROIDS do Dockerfile deles (produção)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/bmtec-src"            # o clone (gitignored)
INDEX="$SRC/index.bin"           # índice construído na hora (gitignored)
TESTDATA="${1:-}"

# --- Localiza o test-data.json oficial (arg > caminho local > erro) ---
if [[ -z "$TESTDATA" ]]; then
  for cand in \
    "$ROOT/test-data.json" \
    "/home/code/rinha2026/rinha-de-backend-2026/test/test-data.json"; do
    [[ -f "$cand" ]] && TESTDATA="$cand" && break
  done
fi
if [[ -z "$TESTDATA" || ! -f "$TESTDATA" ]]; then
  echo "ERRO: test-data.json oficial não encontrado." >&2
  echo "Baixe de github.com/zanfranceschi/rinha-de-backend-2026 (test/test-data.json) e rode:" >&2
  echo "  ./run.sh /caminho/para/test-data.json" >&2
  exit 1
fi

# --- 1. Clona/atualiza o repo do bmtec no commit fixo e o deixa PRISTINO ---
if [[ ! -d "$SRC/.git" ]]; then
  echo "[run] clonando o repo do bmtec ($UPSTREAM)..."
  git clone "$UPSTREAM" "$SRC"
fi
echo "[run] fixando no commit $COMMIT e restaurando árvore original..."
git -C "$SRC" fetch --quiet origin "$COMMIT" 2>/dev/null || git -C "$SRC" fetch --quiet --all
git -C "$SRC" checkout --quiet -f "$COMMIT"
git -C "$SRC" reset  --quiet --hard "$COMMIT"   # descarta qualquer edição anterior (index.rs, Cargo.toml)
rm -f "$SRC/src/bin/exp_eval.rs"                 # remove o avaliador de uma execução anterior (untracked)

# --- 2. Aplica a ÚNICA diferença em relação ao código deles (visível e mínima) ---
#   (a) copia o avaliador
cp "$ROOT/exp_eval.rs" "$SRC/src/bin/exp_eval.rs"
#   (b) registra o binário no Cargo.toml (antes de [dependencies])
if ! grep -q 'name = "exp_eval"' "$SRC/Cargo.toml"; then
  awk '/^\[dependencies\]/ && !done {print "[[bin]]\nname = \"exp_eval\"\npath = \"src/bin/exp_eval.rs\"\n"; done=1} {print}' \
    "$SRC/Cargo.toml" > "$SRC/Cargo.toml.tmp" && mv "$SRC/Cargo.toml.tmp" "$SRC/Cargo.toml"
fi
#   (c) eleva MAX_NPROBE de 64 -> 2048 (só para permitir o KNN EXATO = gabarito).
#       A is_risky_pattern e todo o caminho de produção (nprobe<=64) ficam intactos.
sed -i 's/^const MAX_NPROBE: usize = 64;/const MAX_NPROBE: usize = 2048; \/\/ EXPERIMENT: exact (all-cells) KNN as ground truth/' "$SRC/src/index.rs"

echo
echo "[run] ===== delta exato aplicado ao código do bmtec (git diff) ====="
git -C "$SRC" add -N src/bin/exp_eval.rs   # intent-to-add: faz o arquivo novo aparecer no diff
git -C "$SRC" --no-pager diff --stat
git -C "$SRC" --no-pager diff
echo "[run] ===== fim do delta (acima: tudo o que mudei. nada na busca/is_risky_pattern) ====="
echo

# --- 3. Compila o builder + avaliador (código do bmtec, release) ---
cd "$SRC"
CARGO_TARGET_DIR=target cargo build --release --bin builder --bin exp_eval

# --- 4. Constrói o índice IVF DO ZERO com o builder DELES (k-means determinístico,
#        seed = MAGIC). Sempre reconstrói: nada pré-embutido. ~minutos. ---
echo "[run] construindo o índice IVF do zero (builder do bmtec, $CENTROIDS centróides)..."
CENTROIDS="$CENTROIDS" ./target/release/builder resources/references.json.gz "$INDEX"

# --- 5. Roda o avaliador e salva a saída ---
echo "[run] avaliando..."
./target/release/exp_eval "$INDEX" "$TESTDATA" | tee "$ROOT/RESULTADO.txt"

echo
echo "[run] saída salva em: $ROOT/RESULTADO.txt"
