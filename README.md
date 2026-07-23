# Prova reprodutível — a tabela `is_risky_pattern` do bmtec foi ajustada ao `test-data.json`

Este pacote demonstra, de forma **reproduzível e verificável por qualquer pessoa**, que a
submissão do bmtec
([rinha-backend-2026](https://github.com/bmtec/rinha-backend-2026), e o gêmeo em C
[rinha-backend-2026-c-try](https://github.com/bmtec/rinha-backend-2026-c-try))
zera os erros de detecção no teste **não por busca correta, mas por uma tabela de escalada
(`is_risky_pattern`) calibrada nos payloads específicos do `test-data.json`**.

A regra oficial proíbe exatamente isso
(`docs/br/REGRAS_DE_DETECCAO.md`, `FAQ.md`, `README.md`, `SUBMISSAO.md` do repo da Rinha):

> "Não é permitido usar os payloads do teste como referência ou para fazer lookup de
> fraudes! Os testes finais vão usar outros payloads, e fazer isso nas prévias distorce o
> resultado."

ANN aproximado **é permitido** (`FAQ.md`) — o problema **não** é o IVF. O problema é o
ajuste ao conjunto de teste.

## Nada aqui é embutido

kdkdkj
ssf
bla
bla
bla
bá
kdjkj
ljs
kj

kjd


Este repositório **não contém** o índice, nem o código do bmtec, nem o test-data. O
`run.sh` gera tudo na hora, na sua frente, a partir das fontes públicas:

1. **clona o repo do bmtec** num commit fixo (`0e80820d6664ca744e45f8896650faf44caccb3c`);
2. aplica a **única** diferença (um avaliador novo + uma constante elevada — veja abaixo) e
   **imprime o `git diff` exato** que aplicou, pra você ver que não toquei na busca;
3. compila o `builder` **do próprio bmtec** e **constrói o índice IVF do zero** a partir das
   referências públicas deles (`resources/references.json.gz`). O k-means do builder é
   **determinístico** (seed = `MAGIC`, `CENTROIDS=2048` como no Dockerfile deles), então o
   índice reconstruído é o mesmo de produção;
4. roda o avaliador e grava `RESULTADO.txt`.

## Como reproduzir
este
e
um
te
ste
que lega
```bash
# test-data.json é o oficial da Rinha (não é do bmtec, não vem neste repo):
#   github.com/zanfranceschi/rinha-de-backend-2026 -> test/test-data.json
./run.sh /caminho/para/test-data.json
```

Requisitos: `git`, `cargo` (Rust), conexão pra clonar. A construção do índice leva alguns
minutos (k-means sobre 3 milhões de vetores).

## O que cada configuração mede

O avaliador passa as **54.100 queries oficiais** pela função de busca **do próprio bmtec**
(`query_with_options`), em quatro modos:

- **A — nprobe=10 + tabela (PRODUÇÃO):** o caminho real deles.
- **B — nprobe=10 SEM escalada:** o mesmo, com a tabela desligada (pelos próprios parâmetros
  de opção do código deles: `RepairMode::Bbox` com `repair_min > repair_max`).
- **C — nprobe=48 / D — nprobe=64, SEM escalada:** busca mais profunda, sem tabela.
- **EXACT:** sonda todas as 2048 células = força bruta = KNN exato (o gabarito da Rinha).

Depois cruza A vs B query a query, e repete tudo num conjunto **held-out**: as queries do
teste levemente perturbadas (transações vizinhas não vistas), com o gabarito recalculado por
busca exata.

## Resultado (ver `RESULTADO.txt`)

```
== test-data.json (vs expected_approved) ==
config                                FP    FN   fails
A  nprobe=10  Pattern (PRODUCTION)   0     0     0
B  nprobe=10  no-escalation          3     4     7
C  nprobe=48  no-escalation          0     0     0
D  nprobe=64  no-escalation          0     0     0

EXACT (all 2048 cells) vs expected_approved mismatches: 0  (confirms spec == exact KNN)

== held-out (perturbed, unseen) vs EXACT ground truth ==
queries                 : 54100
B pure-10 failures      : 14
A table   failures      : 13
table fires (A != B)    : 1
rescued (B wrong->A ok) : 1
broke   (B ok->A wrong) : 0
```

**Interpretação:**

- **No `test-data.json`** (onde calibraram): a busca pura nprobe=10 erra **7** (3 FP, 4 FN).
  A tabela dispara em **exatamente essas 7** e conserta **todas (7/7)**, sem quebrar nada.
  No test set inteiro, a `is_risky_pattern` não faz nada **exceto** consertar os 7 pontos que
  o atalho erraria.
- **No held-out** (queries que ela nunca viu, com até *mais* erros a pegar — 14): a tabela
  praticamente **não ativa** (dispara 1×) e conserta só **1 de 14 (~7%)**.
- Uma heurística que **generaliza** reduziria o erro na **mesma proporção** nos dois casos.
  Esta reduz **100% no conjunto calibrado e ~7% fora dele** — a assinatura de ajuste ao
  avaliador, não de um critério geral.
- E o config **C (nprobe=48) zera os mesmos 7 sem tabela nenhuma**: dava pra estar certo de
  forma honesta, só sondando mais células. A busca **EXATA bate 100%** com o gabarito oficial
  (0 mismatches), o que confirma que o gabarito da Rinha É o KNN exato e que a medição está
  correta.

## O que foi modificado no código do bmtec (ver `CHANGES.diff`)

Quase nada — e **nada na lógica de busca**:

1. **Adicionado** `src/bin/exp_eval.rs` (cópia idêntica do `exp_eval.rs` deste repo): o
   avaliador. Só chama a biblioteca pública deles (parser, vetorizador, `query_with_options`).
   Não altera o algoritmo.
2. **Uma linha** em `src/index.rs`: `MAX_NPROBE` de 64 → 2048, para permitir a busca exaustiva
   (gabarito EXATO). **Isso não afeta os configs A/B/C/D** (nprobe ≤ 64): em nprobe=10, `probe`
   é 10 com `MAX_NPROBE` 64 ou 2048. A `is_risky_pattern` e todo o caminho de produção ficam
   **intactos**.
3. Registro do binário `exp_eval` no `Cargo.toml`.

O resultado central (A=0, B=7, a tabela conserta exatamente os 7) reproduz com o código do
bmtec **sem nenhuma alteração de lógica** — apenas com o avaliador adicionado. O `run.sh`
imprime o `git diff` aplicado pra você conferir.

## Ressalvas honestas

- **Não é o "lookup de árvore decorada"** (caso Montano). O bmtec faz KNN real; o atalho
  nprobe=10 já acerta 54.093/54.100 sozinho. O overfit é só o **patch final** que fecha os
  últimos 7 erros decorando-os.
- **O held-out é sintético** (perturbação uniforme ε=0,03 das queries, seed fixa). É um proxy
  de "transações vizinhas não vistas", não o conjunto final oficial. O sinal (7/7 vs 1/14) é
  forte, mas pode ser repetido com outras seeds/ε.
- **Impacto no score:** pela fórmula de `AVALIACAO.md`, os 7 erros sem a tabela dariam
  `absolute_penalty ≈ −361` → detecção ~2639 em vez de 3000 → final ~5639 em vez de 6000.
  A tabela vale ~361 pontos. (Vale **se** o run oficial usou o `test-data.json`; os metadados
  oficiais — total 54100, fraud 23959, edge 645 — batem com esse arquivo.)
