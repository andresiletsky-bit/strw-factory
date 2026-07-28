// Ланцюжок елемента — спека v2 §4.1 п.3, §4.2, §4.3.
//
// Два правила, які v1 не мала:
//  1. КОЖЕН запис ланцюжка проходить CAS по (run_id, epoch). Розбіжність = негайний
//     abort, і жодна дія з ефектом не виконується. У v1 старий воркер після реклейму
//     міг записати результат або відкрити PR.
//  2. НАМІР ПЕРЕД ЕФЕКТОМ. `state: merging` + `pr` + `head_sha` лягають на диск ДО дії.
//     Якщо процес помирає між ними, на диску лишається зачіпка, за якою реконсиляція
//     знайде роботу у світі, — замість `ready` і фальшивого повторного циклу.

import { requireFence } from "./lease.ts";
import { type Item, writeItemFields } from "./items.ts";

/** Запис у item-файл під fence. Кидає CasMismatch, не написавши нічого. */
export function chainWrite(
  repoRoot: string,
  itemPath: string,
  itemId: string,
  runId: string,
  epoch: number,
  fields: Record<string, unknown>,
): Item {
  requireFence(repoRoot, itemId, runId, epoch);
  return writeItemFields(itemPath, fields);
}

/**
 * Намір → ефект. Порядок гарантований:
 *   fence → запис наміру на диск → ефект.
 * Якщо ефект кидає (чи процес убито), намір лишається на диску навмисно.
 */
export function withIntent<T>(
  repoRoot: string,
  itemPath: string,
  itemId: string,
  runId: string,
  epoch: number,
  intent: Record<string, unknown>,
  effect: () => T,
): T {
  chainWrite(repoRoot, itemPath, itemId, runId, epoch, intent);
  return effect();
}
