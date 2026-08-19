// lib.mjs — спільне для скриптів мозку. Нуль залежностей.
//
// Існує через виміряний дрейф: транслітерація жила лише в `split-monoliths.mjs`,
// а `arms.mjs` мав власний слаг без неї — і два таски з кириличними назвами
// («пульт фабрики (ранок)» і «(вечір)») обидва звелись до `strw`, тобто один
// вузол мовчки з'їв інший. Дві копії однієї функції розходяться завжди; питання
// лише, чи помітиш ти це до втрати даних.

export const TRANSLIT = {
  а:"a",б:"b",в:"v",г:"h",ґ:"g",д:"d",е:"e",є:"ie",ж:"zh",з:"z",и:"y",і:"i",ї:"i",
  й:"i",к:"k",л:"l",м:"m",н:"n",о:"o",п:"p",р:"r",с:"s",т:"t",у:"u",ф:"f",х:"kh",
  ц:"ts",ч:"ch",ш:"sh",щ:"shch",ь:"",ю:"iu",я:"ia",ы:"y",э:"e",ъ:"","'":"","’":"",
};

export function slugify(s, max = 50) {
  const t = [...String(s).toLowerCase()].map((c) => TRANSLIT[c] ?? c).join("");
  const cleaned = t.replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
  if (cleaned.length <= max) return cleaned;
  const cut = cleaned.slice(0, max);
  const lastDash = cut.lastIndexOf("-");
  return (lastDash > max * 0.6 ? cut.slice(0, lastDash) : cut).replace(/-+$/, "");
}
