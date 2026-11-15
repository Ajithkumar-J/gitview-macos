#!/bin/sh
# Builds a demo repository and saves screenshots of GitView's windows to
# docs/screenshots. Uses the installed Debug app (scripts/install-local.sh).
# Usage: scripts/take-screenshots.sh [--dark] [--keep]
#   --keep  leave the demo repository in place (to screenshot the Finder menu)
set -eu

cd "$(dirname "$0")/.."
OUT="$PWD/docs/screenshots"
APP="$HOME/Applications/GitView.app/Contents/MacOS/GitView"
WORK="$(mktemp -d)"
DEMO="$WORK/storefront-web"
ORIGIN="$WORK/origin.git"
URL="https://github.com/example/storefront-web.git"
DARK=0; KEEP=0
for arg in "$@"; do
    case "$arg" in --dark) DARK=1 ;; --keep) KEEP=1 ;; esac
done

# Fixed names and dates so the screenshots don't show anyone's real identity.
commit() { # author, days ago, message
    GIT_AUTHOR_NAME="$1" GIT_AUTHOR_EMAIL="$(echo "$1" | tr 'A-Z ' 'a-z.')@example.com" \
    GIT_COMMITTER_NAME="$1" GIT_COMMITTER_EMAIL="$(echo "$1" | tr 'A-Z ' 'a-z.')@example.com" \
    GIT_AUTHOR_DATE="$(date -v-"$2"d '+%Y-%m-%dT%H:%M:%S')" GIT_COMMITTER_DATE="$(date -v-"$2"d '+%Y-%m-%dT%H:%M:%S')" \
    git commit -q -m "$3"
}
git init -q --bare -b main "$ORIGIN"
git init -q -b main "$DEMO"
cd "$DEMO"
git config user.name "Alex Morgan"; git config user.email alex.morgan@example.com
git config commit.gpgsign false
# The remote reads as a GitHub address but points at the local folder.
git remote add origin "$URL"
git config url."$ORIGIN".insteadOf "$URL"

mkdir -p src/api styles
cat > README.md <<'MD'
# Storefront Web
Sample shop front end used to demonstrate GitView.
MD
cat > src/cart.js <<'JS'
import { saveCart, loadCart } from "./storage.js";
import { formatPrice } from "./format.js";

const items = [];

export function addItem(product, quantity = 1) {
  const existing = items.find((item) => item.id === product.id);
  if (existing) {
    existing.quantity += quantity;
  } else {
    items.push({ ...product, quantity });
  }
  saveCart(items);
}

export function removeItem(id) {
  const index = items.findIndex((item) => item.id === id);
  if (index !== -1) items.splice(index, 1);
  saveCart(items);
}

export function cartTotal() {
  let total = 0;
  for (const item of items) {
    total += item.price * item.quantity;
  }
  return total;
}

export function itemCount() {
  return items.reduce((count, item) => count + item.quantity, 0);
}

export function renderSummary(element) {
  element.textContent = `${itemCount()} items · ${formatPrice(cartTotal())}`;
}

export function clearCart() {
  items.length = 0;
}
JS
cat > src/checkout.js <<'JS'
import { cartTotal, clearCart } from "./cart.js";
import { submitOrder } from "./api/orders.js";

export async function checkout(order) {
  order.total = cartTotal();
  const receipt = await submitOrder(order);
  clearCart();
  return receipt;
}
JS
cat > styles/site.css <<'CSS'
:root {
  --accent: #2563eb;
  --text: #111827;
}

header {
  display: flex;
  align-items: center;
  gap: 12px;
}
CSS
git add . && commit "Alex Morgan" 12 "Initial storefront skeleton"
cat > src/api/orders.js <<'JS'
export async function submitOrder(order) {
  const response = await fetch("/api/orders", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(order),
  });
  return response.json();
}
JS
git add . && commit "Priya Shah" 10 "Add orders API client"
printf '\nexport const TAX_RATE = 0.08;\n' >> src/checkout.js
git add . && commit "Sam Lee" 8 "Apply sales tax at checkout"
printf '\n@media (prefers-color-scheme: dark) {\n  :root { --text: #f9fafb; }\n}\n' >> styles/site.css
git add . && commit "Priya Shah" 6 "Support dark mode in the header"
printf '\nexport const MAX_RETRIES = 3;\n' >> src/api/orders.js
git add . && commit "Alex Morgan" 4 "Retry failed order requests"
git push -q -u origin main
for branch in release/2.4 feature/search-suggestions feature/gift-cards hotfix/cart-total; do
    git push -q origin "main:refs/heads/$branch"
done
git branch -q feature/search-suggestions origin/feature/search-suggestions
git branch -q release/2.4 origin/release/2.4

# Two commits on the server that Pull will show as incoming.
git -c url."$ORIGIN".insteadOf="$URL" clone -q "$URL" "$WORK/teammate"
( cd "$WORK/teammate" && git config url."$ORIGIN".insteadOf "$URL" && git config commit.gpgsign false
  printf 'export const FREE_SHIPPING_OVER = 50;\n' >> src/checkout.js && git add . && commit "Sam Lee" 2 "Free shipping for orders over 50"
  printf '\n:focus-visible { outline: 2px solid var(--accent); }\n' >> styles/site.css && git add . && commit "Priya Shah" 1 "Visible focus rings for keyboard users"
  git push -q origin main )
git fetch -q origin

# Local work in progress: three separate edits in cart.js, one staged file, one new file.
perl -0pi -e 's/const items = \[\];/const items = loadCart() ?? [];/;
  s/  let total = 0;\n  for \(const item of items\) \{\n    total \+= item.price \* item.quantity;\n  \}\n  return total;/  return items.reduce((sum, item) => sum + item.price * item.quantity, 0);/;
  s/  items.length = 0;\n/  items.length = 0;\n  saveCart(items);\n/' src/cart.js
perl -0pi -e 's/  order.total = cartTotal\(\);/  validateAddress(order.shipping);\n  order.total = cartTotal();/' src/checkout.js
git add src/checkout.js
printf 'export function applyCoupon(order, code) {\n  return code === "WELCOME10" ? order.total * 0.9 : order.total;\n}\n' > src/coupons.js
cd - >/dev/null

osascript -e 'quit app "GitView"' 2>/dev/null || true
sleep 1
mkdir -p "$OUT"
GITVIEW_SCREENSHOTS="$OUT" GITVIEW_SCREENSHOT_REPO="$DEMO" GITVIEW_SCREENSHOT_DARK="$DARK" "$APP"
ls -1 "$OUT"

if [ "$KEEP" = 1 ]; then
    echo "Demo repository kept at $DEMO"
else
    rm -rf "$WORK"
fi
