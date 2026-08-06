# DRY Eyes

![DRY Eyes](../assets/Background.png)

**Encuentra duplicación semántica de código para [Claude Code](https://claude.com/claude-code)
— la misma regla de negocio, cálculo o patrón de UI/UX implementado de forma
independiente más de una vez, muchas veces con comportamiento diferente en cada versión.**

![Claude Code](https://img.shields.io/badge/Claude_Code-compatible-0F6E56)

![Cómo funciona DRY Eyes](../assets/how-it-works-es.png)

> Encuentra la misma regla de negocio, cálculo o patrón de UI/UX
> implementado de forma independiente más de una vez — muchas veces con
> **comportamiento diferente en cada versión** — y compara cada variante
> contra las demás y contra lo que una implementación correcta realmente
> necesitaría. No es un detector de copia literal: jscpd y PMD-CPD ya
> encuentran clones textuales de forma barata. Esto es para la duplicación
> que esas herramientas no pueden ver.

*[Read in English](../README.md) · [Leia em português](./README.pt-BR.md)*

## Por qué existe

Dos implementaciones de la misma regla rara vez se ven idénticas cuando
alguien las reimplementa de forma independiente — nombres distintos, forma
distinta, a veces una convención de nombres de variables completamente
distinta. Un detector de clones por coincidencia literal es rápido y
determinístico para detectar copia y pega, pero no puede decirte que una
pantalla que muestra un toast de error y tres pantallas que no lo muestran
deberían tratar la misma falla de la misma forma, o que tres archivos
calculan "el mismo" descuento con tres bugs de casos límite distintos.

DRY Eyes ejecuta primero señales baratas y determinísticas de generación de
candidatos (literales de cadena repetidos, rutas de archivo reflejadas,
líneas normalizadas compartidas, familias de nombres filtradas por dominio,
mecanismos de UI inconsistentes para una misma preocupación) — por la misma
razón que existen esos detectores de clones: la mayoría de los candidatos no
necesita una llamada a un LLM para salir a la luz. Lo que cambia es lo que
pasa después: cada candidato real se lee y se compara por comportamiento
real, no solo por similitud textual. El trabajo de la comparación es
averiguar qué requiere una implementación *correcta* del concepto,
independientemente de cualquier variante en particular, y luego comprobar
cada variante contra ese criterio. Es común — no raro — que la respuesta sea
"ninguna de ellas", con una descripción de lo que una implementación
correcta todavía necesitaría cubrir.

## Instalación

```bash
npx dry-eyes install --project   # .claude/skills/dry-eyes de este repositorio
# o, sin --project, instala globalmente en ~/.claude/skills/user/dry-eyes
```

Puede que se necesite una sesión nueva de Claude Code después para que el
skill sea descubierto (los skills se leen al inicio de la sesión).

<details>
<summary>Instalar desde un clon local (para contribuir al propio DRY Eyes)</summary>

```bash
git clone https://github.com/kigiela/dry-eyes.git
cd dry-eyes
node bin/cli.js install --project
```

</details>

## Uso

```
/dry-eyes init   configura — patrones de exclusión, ubicación de salida,
                 ámbitos, sondas de duplicación; se ejecuta solo si se omite
/dry-eyes scan   escanea todo el repositorio, agrupa candidatos, verifica
                 cada uno con escepticismo, compara el comportamiento real de cada variante
```

## Cómo funciona

1. **Perfila una vez, persiste.** `/dry-eyes init` perfila los paquetes y
   lenguajes del repo, luego diseña un conjunto a medida de categorías
   propensas a duplicación (validación, cálculos, mecanismos de
   visualización de errores, ...) — hecho una sola vez, reutilizado por
   cada escaneo futuro, nunca rediseñado en cada ejecución.
2. **Señales baratas primero.** `/dry-eyes scan` ejecuta cinco señales
   determinísticas — literales repetidos, rutas reflejadas, formas de línea
   compartidas, familias de nombres filtradas por dominio, mecanismos
   inconsistentes para una misma preocupación — combinando la concordancia
   entre señales en candidatos únicos antes de que ocurra cualquier llamada
   a un LLM.
3. **Verificación escéptica.** Cada clúster candidato se lee de verdad y se
   comprueba: ¿es realmente el mismo concepto, reimplementado de forma
   independiente — o ya está compartido, es coincidencia, o son dos cosas
   que en realidad deberían permanecer desacopladas?
4. **Comparación independiente, no una votación por el "ganador".** Para
   los clústeres cuyas variantes realmente divergen en comportamiento,
   varios análisis independientes derivan qué requiere el comportamiento
   *correcto* **antes** de mirar cualquier variante — y solo entonces
   comprueban cada variante contra ese criterio. El desacuerdo entre
   análisis se arbitra, no se decide por votación: la conclusión que una
   mayoría convergente tiene más probabilidades de pasar por alto es
   precisamente "ninguna de ellas es correcta".
5. **Un informe, no una corrección.** Markdown + JSON, liderado por los
   clústeres que necesitan una decisión humana. Solo lectura — la v1 no
   tiene comando `fix`.

## Lo que la v1 no hace

- **Sin comando `fix`.** El informe JSON lleva un id estable y una
  clasificación tipo safe/risky por clúster específicamente para que un
  futuro `dry-eyes fix` pueda consumirlo — aplicar una consolidación es una
  acción distinta y de mayor riesgo que simplemente reportarla.
- **Sin modo limitado a diff/PR.** La detección de duplicación es
  inherentemente una comparación con todo el repositorio — para saber si
  código nuevo duplica algo, ese "algo" casi siempre está fuera del diff.
  Una versión fiel limitada al diff tendría que escanear todo el repositorio
  de todos modos, perdiendo el ahorro de costo que justifica un modo diff en
  primer lugar.
- **Sin comparación entre lenguajes.** Cada ámbito es exactamente un
  lenguaje.
- **Sin integración de CI, sin adaptadores multi-herramienta.** Solo Claude
  Code en la v1 — este pipeline depende mucho más de código determinístico
  real (agrupamiento, fusión por Jaccard, una protección contra
  alucinación de rutas) de lo que una portación vía JSON-en-prompt a los
  subagentes de otra herramienta podría reproducir de forma confiable.
- **Alta precisión, recall medio, a propósito — y cada informe lo dice.**
  La duplicación sin literal repetido, sin nombre compartido, sin forma de
  línea similar y sin ruta reflejada es invisible para las señales
  determinísticas; el barrido complementario por LLM solo la detecta si se
  diseñó alguna categoría para esa área.

## Licencia

MIT — ver [LICENSE](LICENSE).
