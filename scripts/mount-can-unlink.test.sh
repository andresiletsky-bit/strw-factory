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
# ФІКСТУРА СПРАВЖНЬОЇ НЕВИДАЛИМОСТІ — тека, в якій СТВОРИТИ можна, а ВИДАЛИТИ ні,
# як у tri-073: на macOS без root це ACL `chmod +a "<user> deny delete_child"`
# на теці (`rm` → Permission denied, файл лишається) — проба (c) запускає
# предмет проти неї. На Linux без root такої фікстури немає (`chattr +i` на
# теці забороняє і створення, тобто дає 2, а не 1; +i на файлі потребує
# CAP_LINUX_IMMUTABLE) — тоді (c) каже про це ВГОЛОС рядком SKIP, а клас
# «створити можна, видалити ні» тримає підміна `rm` (b). Мовчазного пропуску
# немає: SKIP названий, не зелений.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$PWD/scripts/mount-can-unlink.sh"
pass=0; fail=0
TMP="$(mktemp -d)"

# Знімаємо незнищенність ДО rm -rf, інакше тека лишиться після набору —
# тобто набір сам відтворить дефект, про який він.
cleanup() {
    if [ -n "${ACL_DIR:-}" ] && [ -d "$ACL_DIR" ]; then
        chmod -a "$(id -un) deny delete_child,delete" "$ACL_DIR" 2>/dev/null || true
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
find "$TMP/liar/work" -type f -exec /bin/rm -f {} + 2>/dev/null || true

# ── (c) СПРАВЖНЯ невидалимість: створити можна, видалити ні → 1 ─────────────
# macOS: ACL deny delete_child на теці — рівно поведінка tri-073 без root.
mkdir -p "$TMP/acl/work"
ACL_DIR=""
if chmod +a "$(id -un) deny delete_child,delete" "$TMP/acl/work" 2>/dev/null; then
    ACL_DIR="$TMP/acl/work"
    : > "$ACL_DIR/.canary"
    if /bin/rm -f "$ACL_DIR/.canary" 2>/dev/null; [ -e "$ACL_DIR/.canary" ]; then
        want 1 "(c) справжня невидалимість (ACL deny delete_child): створити можна, rm не працює → 1" "$ACL_DIR" "монтування не видаляє файли"
        # негативний контроль: та сама тека без ACL → 0 (інакше (c) зелена з іншої причини)
        chmod -a "$(id -un) deny delete_child,delete" "$ACL_DIR" 2>/dev/null
        /bin/rm -f "$ACL_DIR"/.canary "$ACL_DIR"/.strw-mount-probe.* 2>/dev/null
        want 0 "(c') та сама тека після зняття ACL → 0 (червоніло саме через ACL)" "$ACL_DIR" "дозволено"
        ACL_DIR=""
    else
        printf 'FAIL %s\n' "(c) ACL встановлено, але rm усе одно видаляє — фікстура не моделює tri-073"; fail=$((fail+1))
    fi
else
    printf 'SKIP %s\n' "(c) справжньої невидалимості без root тут немає (Linux: chattr +i на теці дає 2, не 1) — клас тримає (b)"
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

# ── (g') один рядок stdout і для кодів 1 та 2 (Step 0 читає вердикт на всіх трьох) ──
out1=$(PATH="$TMP/liar/bin:$PATH" bash "$TOOL" "$TMP/liar/work" 2>/dev/null); l1=$(printf '%s\n' "$out1" | wc -l | tr -d ' ')
out2=$(bash "$TOOL" "$TMP/nema" 2>/dev/null); l2=$(printf '%s\n' "$out2" | wc -l | tr -d ' ')
if [ "$l1" = 1 ] && printf '%s' "$out1" | grep -q "ЗАБОРОНЕНО" && [ "$l2" = 1 ] && printf '%s' "$out2" | grep -q "не поміряти"; then
    printf 'ok   %s\n' "(g') коди 1 і 2 — теж рівно один рядок вердикту в stdout"; pass=$((pass+1))
else printf 'FAIL %s (рядків %s/%s)\n' "(g') коди 1 і 2 — один рядок вердикту" "$l1" "$l2"; fail=$((fail+1)); fi
find "$TMP/liar/work" -type f -exec /bin/rm -f {} + 2>/dev/null || true

# ── (j) у git-репо проба лягає в .git/, не в робоче дерево ────────────────
mkdir -p "$TMP/repo/.git" "$TMP/repo/logbin"
cat > "$TMP/repo/logbin/touch" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$PROBE_LOG"
: > "$1"
STUB
chmod +x "$TMP/repo/logbin/touch"
PROBE_LOG="$TMP/repo/log"; : > "$PROBE_LOG"
PATH="$TMP/repo/logbin:$PATH" PROBE_LOG="$PROBE_LOG" bash "$TOOL" "$TMP/repo" >/dev/null 2>&1
if grep -q "^$TMP/repo/\.git/\.strw-mount-probe\." "$PROBE_LOG"; then
    printf 'ok   %s\n' "(j) у репо проба створюється в .git/ (поверхня відмови, поза робочим деревом)"; pass=$((pass+1))
else printf 'FAIL %s\n' "(j) у репо проба створюється в .git/"; sed 's/^/       /' "$PROBE_LOG"; fail=$((fail+1)); fi

# ── (i) ШЛЯХ ПРОБИ УНІКАЛЬНИЙ НА ПРОЦЕС ────────────────────────────────────
# Куплено знахідкою чекера PR #18 (Important): мутація `.strw-mount-probe.$$`
# → `.strw-mount-probe` ВИЖИВАЛА під усіма дев'ятьма пробами й під п'ятьма
# мутаціями maker'а. Коментар скрипта називав причину `$$` («щоб два паралельні
# заходи не міряли той самий файл»), але жоден свідок її не тримав — тобто
# властивість жила в прозі, рівно як правило без механізму.
#
# Сценарій відмови, який це закриває: два headless-заходи в одній теці. A
# видаляє свій probe (unlink працює), і рівно в цю мить B своїм `touch` створює
# файл ПІД ТИМ САМИМ іменем; A доходить до `[ -e "$probe" ]`, бачить файл і
# ХИБНО каже «git ЗАБОРОНЕНО» на справному монтуванні. Тобто зливаються стани
# 0 і 1 — рівно те, проти чого написана вся проба.
#
# Вимір детермінований, а не гонитвою: `touch` підмінено накопичувачем, який
# записує шлях, що його просили створити. Два послідовні прогони — два РІЗНІ
# процеси, отже два різні `$$`; без унікалізації шляхи збіглися б.
mkdir -p "$TMP/uniq/bin" "$TMP/uniq/work"
cat > "$TMP/uniq/bin/touch" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$PROBE_LOG"
: > "$1"
STUB
chmod +x "$TMP/uniq/bin/touch"
PROBE_LOG="$TMP/uniq/log"; : > "$PROBE_LOG"
PATH="$TMP/uniq/bin:$PATH" PROBE_LOG="$PROBE_LOG" bash "$TOOL" "$TMP/uniq/work" >/dev/null 2>&1
PATH="$TMP/uniq/bin:$PATH" PROBE_LOG="$PROBE_LOG" bash "$TOOL" "$TMP/uniq/work" >/dev/null 2>&1
total_n=$(wc -l < "$PROBE_LOG" | tr -d ' ')
uniq_n=$(sort -u "$PROBE_LOG" | wc -l | tr -d ' ')
if [ "$total_n" = "2" ] && [ "$uniq_n" = "2" ]; then
    printf 'ok   %s\n' "(i) два процеси — два РІЗНІ шляхи проби (паралельні заходи не перегоняться)"; pass=$((pass+1))
else printf 'FAIL %s (спроб %s, унікальних %s)\n' "(i) два процеси — два РІЗНІ шляхи проби" "$total_n" "$uniq_n"
     sed 's/^/       /' "$PROBE_LOG"; fail=$((fail+1)); fi

# ── (h) без аргументу — поточна тека, не мовчазна відмова ──────────────────
mkdir -p "$TMP/cwd"
out=$(cd "$TMP/cwd" && bash "$TOOL" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "дозволено"; then
    printf 'ok   %s\n' "(h) без аргументу міряє поточну теку"; pass=$((pass+1))
else printf 'FAIL %s (код %d/0)\n' "(h) без аргументу міряє поточну теку" "$rc"
     printf '%s\n' "$out" | sed 's/^/       /'; fail=$((fail+1)); fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
