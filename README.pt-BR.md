# DRY Eyes

![DRY Eyes](./assets/Background.png)

**Encontra duplicação semântica de código para [Claude Code](https://claude.com/claude-code)
— a mesma regra de negócio, cálculo ou padrão de UI/UX implementado de forma
independente mais de uma vez, muitas vezes com comportamento diferente em cada versão.**

![Claude Code](https://img.shields.io/badge/Claude_Code-suportado-0F6E56)

![Como o DRY Eyes funciona](./assets/how-it-works-pt-br.png)

> Encontra a mesma regra de negócio, cálculo ou padrão de UI/UX implementado
> de forma independente mais de uma vez — muitas vezes com **comportamento
> diferente em cada versão** — e compara cada variante contra as outras e
> contra o que uma implementação correta de fato exigiria. Não é um detector
> de cópia literal: jscpd e PMD-CPD já encontram clones textuais de forma
> barata. Isso é para a duplicação que essas ferramentas não enxergam.

*[Read in English](./README.md) · [Lee en español](./README.es.md)*

## Por que isso existe

Duas implementações da mesma regra raramente ficam idênticas quando alguém as
reimplementa de forma independente — nomes diferentes, formato diferente, às
vezes uma convenção de nomenclatura de variável completamente diferente. Um
detector de clones por comparação literal é rápido e determinístico pra
achar cópia-e-cola, mas não consegue te dizer que uma tela mostrando um toast
de erro e três telas que não mostram deveriam todas tratar a mesma falha da
mesma forma, ou que três arquivos calculam "o mesmo" desconto com três bugs
de edge case diferentes.

O DRY Eyes roda primeiro sinais baratos e determinísticos de geração de
candidatos (literais de string repetidos, caminhos de arquivo espelhados,
linhas normalizadas compartilhadas, famílias de nomes filtradas por domínio,
mecanismos de UI inconsistentes pra uma mesma preocupação) — pelo mesmo
motivo que esses detectores de clone existem: a maioria dos candidatos não
precisa de uma chamada de LLM pra aparecer. O que muda é o que acontece
depois: todo candidato real é lido e comparado por comportamento de verdade,
não só por semelhança textual. O trabalho da comparação é descobrir o que
uma implementação *correta* do conceito exige, independente de qualquer
variante específica, e então checar cada variante contra essa régua. É
comum — não raro — a resposta ser "nenhuma delas", com uma descrição do que
uma implementação correta ainda precisaria tratar.

## Instalação

```bash
npx dry-eyes install --project   # .claude/skills/dry-eyes deste repositório
# ou, sem --project, instala globalmente em ~/.claude/skills/user/dry-eyes
```

Uma sessão nova do Claude Code pode ser necessária depois pra skill ser
descoberta (skills são lidos no início da sessão).

<details>
<summary>Instalando a partir de um clone local (pra contribuir com o próprio DRY Eyes)</summary>

```bash
git clone https://github.com/kigiela/dry-eyes.git
cd dry-eyes
node bin/cli.js install --project
```

</details>

## Uso

```
/dry-eyes init   configura — padrões de exclusão, local de saída, escopos,
                 probes de duplicação; roda sozinho e sem perguntas se pulado
/dry-eyes scan   varre o repositório inteiro, agrupa candidatos, verifica
                 cada um ceticamente, compara o comportamento real de cada variante
```

## Como funciona

1. **Perfila uma vez, persiste.** `/dry-eyes init` perfila os pacotes e
   linguagens do repo, depois desenha um conjunto sob medida de categorias
   propensas a duplicação (validação, cálculos, mecanismos de exibição de
   erro, ...) — feito uma vez, reaproveitado por todo scan futuro, nunca
   redesenhado a cada execução.
2. **Sinais baratos primeiro.** `/dry-eyes scan` roda cinco sinais
   determinísticos — literais repetidos, caminhos espelhados, formas de
   linha compartilhadas, famílias de nomes filtradas por domínio, mecanismos
   inconsistentes pra uma mesma preocupação — juntando a concordância entre
   sinais em candidatos únicos antes de qualquer chamada de LLM acontecer.
3. **Verificação cética.** Todo cluster candidato é lido de verdade e
   checado: isso é realmente o mesmo conceito, reimplementado de forma
   independente — ou já é compartilhado, coincidência, ou são duas coisas
   que deveriam mesmo ficar desacopladas?
4. **Comparação independente, não uma votação pelo "vencedor".** Pros
   clusters cujas variantes realmente divergem em comportamento, várias
   análises independentes derivam o que o comportamento *correto* exige
   **antes** de olhar pra qualquer variante — e só então checam cada
   variante contra essa régua. Discordância entre análises é arbitrada, não
   decidida por votação: a conclusão que uma maioria convergente tem mais
   chance de deixar passar é justamente "nenhuma delas está certa".
5. **Um relatório, não uma correção.** Markdown + JSON, liderado pelos
   clusters que precisam de uma decisão humana. Somente leitura — a v1 não
   tem comando `fix`.

## O que a v1 não faz

- **Sem comando `fix`.** O relatório JSON carrega um id estável e uma
  classificação estilo safe/risky por cluster especificamente pra um futuro
  `dry-eyes fix` poder consumir — aplicar uma consolidação é uma ação
  diferente e de risco mais alto do que só reportar uma.
- **Sem modo escopado a diff/PR.** Duplicação de código é inerentemente uma
  comparação com o repositório inteiro — pra saber se código novo duplica
  algo, o "algo" quase sempre está fora do diff. Uma versão escopada a diff
  fiel teria que varrer o repo inteiro de qualquer forma, perdendo a
  economia de custo que justifica um modo diff em primeiro lugar.
- **Sem comparação entre linguagens.** Todo escopo é exatamente uma
  linguagem.
- **Sem integração de CI, sem adaptadores multi-ferramenta.** Só Claude Code
  na v1 — esse pipeline depende muito mais de código determinístico de
  verdade (agrupamento, junção por Jaccard, uma trava contra alucinação de
  caminho) do que uma portagem via JSON-em-prompt pros subagentes de outra
  ferramenta conseguiria reproduzir de forma confiável.
- **Alta precisão, recall médio, de propósito — e todo relatório avisa
  isso.** Duplicação sem literal repetido, sem nome compartilhado, sem forma
  de linha parecida e sem caminho espelhado é invisível pros sinais
  determinísticos; a varredura complementar por LLM só encontra se alguma
  categoria tiver sido desenhada pra aquela área.

## Licença

MIT — ver [LICENSE](LICENSE).
