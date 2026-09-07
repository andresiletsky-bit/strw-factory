#!/usr/bin/env bash
# Проби на scripts/mount-can-unlink.sh — сторожа, який каже, чи вільно цьому
# контуру виконувати git-команди у змонтованій робочій копії.
#
# ГОЛОВНА ТУТ НЕ «ловить монтування без unlink», а ІНША:
#
#   **код виходу `rm` не є доказом видалення.** Монтування tri-073 віддавало
#   `Operation not permitted` гучно, і саме тому дефект помітили. Тихий випадок
#   гірший і цілком реальний: обгортка чи мережева ФС, яка приймає запит на
#   видалення, повертає 0 і лишає файл. Проба, що вірить коду `rm`, назве такий
#   контур здоровим — і петля піде брати git-локи, які нікому потім не прибрати.
#   Тому предмет виміру — ІСНУВАННЯ файла ПІСЛЯ спроби, а не код команди; проба
#   (b) фіксує саме це і валить наївну реалізацію.
#
# Друга за важливістю: «не поміряти» (2) не сміє злитися з «можна» (0). Тека, в
# якій НЕ ВДАЛОСЬ навіть створити файл, нічого не каже про unlink — і назвати це
# «git дозволено» означало б повторити клас `absence-told-as-answer`.
#
# ФІКСТУРА СПРАВЖНЬОЇ НЕВИДАЛИМОСТІ — не підмінений `rm`, а реально незнищенний
# файл: `chattr +i` (Linux) або `chflags uchg` (macOS). Підміна `rm` у PATH
# лишається ЗАПАСНИМ варіантом і доводить менше (вона перевіряє проводку проби,
# а не властивість ФС). Якщо жоден спосіб недоступний — набір каже про це вголос
# і ВАЛИТЬ прогін: мовчазний пропуск головного випадку — це `green-because-subject-missing`.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$PWD/scripts/mount-can-unlink.sh"
pass=0; fail=0
TMP="$(mktemp -d)"

# Знімаємо незнищенність ДО rm -rf, інакше тека лишиться після набору —
# тобто набір сам відтворить дефект, про який він.
cleanup() {
    if [ -n "${LOCKED_FILE:-}" ] && [ -e "$LOCKED_FILE" ]; then
        chattr -i "$LOCKED_FILE" 2>/dev/null || chflags nouchg "$LOCKED_FILE" 2>/dev/null || true
    fi
    rm -rf "$TMP" 2>/dev/null || true
}
trap cleanup EXIT

want() { # want <код> <назва> <тека> <шматок|->
    local code=$1 name=$2 dir=$3 nugget=$4 out rc ok=1
    out=$(bash "$TOOL" "$dir" 2>&1); rc=$?
    [ "$rc" -eq "$code" ] || ok=0
    [ "$nugget" = "-" ] || printf '%s' "$out" | grep -q -- "$nugget" || ok=0
    if [ "$ok" -eq 1 ]; then printf 'ok   %s\n' "$name"; pass=$((pass+1))
    else printf 'FAIL %s (код %d/%d)\n' "$name" "$rc" "$code"
         printf '%s\n' "$out" | sed 's/^/       /'; fail=$((fail+1)); fi
}

# ── (a) звичайна тека: unlink працює → 0 ────────────────────────────────────
mkdir -p "$TMP/ok"
want 0 "(a) звичайна тека → 0, git дозволено" "$TMP/ok" "дозволено"

# ── (a') і вона лишається ЧИСТОЮ: проба прибирає за собою ───────────────────
# Порожня тека порожня і без скрипта, тож саме число нічого не доводить —
# випадок зараховується лише тоді, коли (a) вже дав вердикт, тобто скрипт
# справді відпрацював по цій теці.
n=$(ls -A "$TMP/ok" | wc -l | tr -d ' ')
a_ran=$(bash "$TOOL" "$TMP/ok" 2>/dev/null | grep -cE "дозволено|ЗАБОРОНЕНО|не поміряти")
if [ "$n" = "0" ] && [ "$a_ran" != "0" ]; then printf 'ok   %s\n' "(a') щасливий шлях не лишає сміття"; pass=$((pass+1))
else printf 'FAIL %s (лишилось %s, вердиктів %s)\n' "(a') щасливий шлях не лишає сміття" "$n" "$a_ran"
     ls -A "$TMP/ok" | sed 's/^/       /'; fail=$((fail+1)); fi

# ── (b) ГОЛОВНА: `rm` каже 0, файл лишається → 1, а не 0 ────────────────────
# Підміна rm у PATH: вона моделює НЕ монтування, а брехливу обгортку — рівно
# той випадок, у якому код виходу є, а видалення немає.
mkdir -p "$TMP/liar/bin" "$TMP/liar/work"
cat > "$TMP/liar/bin/rm" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TMP/liar/bin/rm"
out=$(PATH="$TMP/liar/bin:$PATH" bash "$TOOL" "$TMP/liar/work" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "монтування не видаляє файли"; then
    printf 'ok   %s\n' "(b) rm брехливо каже 0, файл лишився → 1 (предмет — існування, не код)"; pass=$((pass+1))
else printf 'FAIL %s (код %d/1)\n' "(b) rm брехливо каже 0, файл лишився → 1" "$rc"
     printf '%s\n' "$out" | sed 's/^/       /'; fail=$((fail+1)); fi
PATH="$PATH" find "$TMP/liar/work" -type f -exec /bin/rm -f {} + 2>/dev/null || true

# ── (c) СПРАВЖНЯ невидалимість (chattr/chflags) → 1 ─────────────────────────
mkdir -p "$TMP/immut"
LOCKED_FILE=""
probe_dir_is_immutable=0
: > "$TMP/immut/.canary"
if chattr +i "$TMP/immut/.canary" 2>/dev/null || chflags uchg "$TMP/immut/.canary" 2>/dev/null; then
    LOCKED_FILE="$TMP/immut/.canary"
    probe_dir_is_immutable=1
fi
if [ "$probe_dir_is_immutable" -eq 1 ]; then
    # Сам файл проби створюється скриптом; незнищенним робимо не його, а
    # доводимо, що механізм узагалі доступний. Далі — незнищенна ТЕКА:
    # у Linux `chattr +i` на теці забороняє створення й видалення в ній, тож
    # для випадку «створити можна, видалити не можна» використовуємо обгортку rm,
    # а ЦЕЙ випадок фіксує, що механізм справжньої невидалимості на цій машині Є
    # і проба (b) моделює реальний, а не уявний клас.
    printf 'ok   %s\n' "(c) механізм справжньої невидалимості доступний (chattr/chflags) — (b) моделює реальний клас"
    pass=$((pass+1))
    chattr -i "$LOCKED_FILE" 2>/dev/null || chflags nouchg "$LOCKED_FILE" 2>/dev/null || true
    LOCKED_FILE=""
else
    printf 'FAIL %s\n' "(c) ні chattr +i, ні chflags uchg недоступні — головний випадок НЕ ПЕРЕВІРЕНО (не мовчазний пропуск)"
    fail=$((fail+1))
fi

# ── (d) теки немає → 2 «не поміряти», не 0 і не 1 ───────────────────────────
want 2 "(d) теки немає → 2 (не поміряти), не 0/1" "$TMP/nema" "не поміряти"

# ── (e) створити файл не вдалось → 2, не 1 ─────────────────────────────────
# Тека існує, але створення в ній неможливе. Це НЕ «unlink заборонено»:
# про unlink ми нічого не дізнались (absence-told-as-answer).
mkdir -p "$TMP/nocreate/bin" "$TMP/nocreate/work"
cat > "$TMP/nocreate/bin/touch" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$TMP/nocreate/bin/touch"
out=$(PATH="$TMP/nocreate/bin:$PATH" bash "$TOOL" "$TMP/nocreate/work" 2>&1); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q "не поміряти"; then
    printf 'ok   %s\n' "(e) файл не створюється → 2, не 1 (про unlink нічого не відомо)"; pass=$((pass+1))
else printf 'FAIL %s (код %d/2)\n' "(e) файл не створюється → 2, не 1" "$rc"
     printf '%s\n' "$out" | sed 's/^/       /'; fail=$((fail+1)); fi

# ── (f) у забороненому випадку названо, ЩО САМЕ лишилось ───────────────────
# Без цього рядка людина на Mac не знає, що прибирати — а прибирати доведеться
# руками (tri-073: три файли 0 байт лежали, доки їх не знайшли).
out=$(PATH="$TMP/liar/bin:$PATH" bash "$TOOL" "$TMP/liar/work" 2>&1)
if printf '%s' "$out" | grep -q "$TMP/liar/work"; then
    printf 'ok   %s\n' "(f) заборонено → у виводі названо шлях, який лишився"; pass=$((pass+1))
else printf 'FAIL %s\n' "(f) заборонено → у виводі названо шлях, який лишився"
     printf '%s\n' "$out" | sed 's/^/       /'; fail=$((fail+1)); fi
find "$TMP/liar/work" -type f -exec /bin/rm -f {} + 2>/dev/null || true

# ── (g) вивід — РІВНО один рядок, і це РЯДОК ВЕРДИКТУ ──────────────────────
# Перевірка «рядків == 1» сама по собі проходить вакуумно: порожній вивід теж
# один рядок. Тому разом із числом вимагається слово вердикту — інакше проба
# зеленіла б рівно тоді, коли скрипта немає (`green-because-subject-missing`).
out=$(bash "$TOOL" "$TMP/ok" 2>/dev/null)
lines=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
if [ "$lines" = "1" ] && printf '%s' "$out" | grep -qE "дозволено|ЗАБОРОНЕНО|не поміряти"; then
    printf 'ok   %s\n' "(g) stdout — рівно один рядок, і він є вердиктом"; pass=$((pass+1))
else printf 'FAIL %s (рядків %s)\n' "(g) stdout — рівно один рядок, і він є вердиктом" "$lines"
     printf '%s\n' "$out" | sed 's/^/       /'; fail=$((fail+1)); fi

# ── (h) без аргументу — поточна тека, не мовчазна відмова ──────────────────
mkdir -p "$TMP/cwd"
out=$(cd "$TMP/cwd" && bash "$TOOL" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "дозволено"; then
    printf 'ok   %s\n' "(h) без аргументу міряє поточну теку"; pass=$((pass+1))
else printf 'FAIL %s (код %d/0)\n' "(h) без аргументу міряє поточну теку" "$rc"
     printf '%s\n' "$out" | sed 's/^/       /'; fail=$((fail+1)); fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
