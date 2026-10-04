"""Generates the UML use-case and sequence diagrams (matplotlib only)."""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Ellipse, Rectangle, FancyBboxPatch

OUT = ".."

# ------------------------------------------------------------------ use case
def stick(ax, x, y, label):
    ax.add_patch(plt.Circle((x, y + 0.55), 0.17, fill=False, lw=1.6))
    ax.plot([x, x], [y + 0.38, y - 0.15], c="k", lw=1.6)
    ax.plot([x - 0.3, x + 0.3], [y + 0.22, y + 0.22], c="k", lw=1.6)
    ax.plot([x, x - 0.25], [y - 0.15, y - 0.65], c="k", lw=1.6)
    ax.plot([x, x + 0.25], [y - 0.15, y - 0.65], c="k", lw=1.6)
    ax.text(x, y - 0.95, label, ha="center", va="top", fontsize=10, fontweight="bold")

def usecase():
    fig, ax = plt.subplots(figsize=(11, 7.4), dpi=170)
    ax.set_xlim(0, 11); ax.set_ylim(0, 7.4); ax.axis("off")
    ax.add_patch(Rectangle((2.3, 0.3), 6.4, 6.8, fill=False, lw=1.6))
    ax.text(5.5, 6.85, "BankLedger system", ha="center", fontsize=12, fontweight="bold")

    left = ["Create customer", "Open account", "Deposit", "Withdraw",
            "Transfer funds", "View balance / statement"]
    right = ["Freeze / close account", "Process batch queue",
             "Apply monthly interest", "View reports", "View audit log", "Backup database"]
    pos = {}
    for i, t in enumerate(left):
        y = 6.1 - i * 0.95
        ax.add_patch(Ellipse((3.9, y), 2.9, 0.72, fc="#e3f2fd", ec="k"))
        ax.text(3.9, y, t, ha="center", va="center", fontsize=9)
        pos[t] = (2.45, y)
    for i, t in enumerate(right):
        y = 6.1 - i * 0.95
        ax.add_patch(Ellipse((7.1, y), 2.9, 0.72, fc="#e8f5e9", ec="k"))
        ax.text(7.1, y, t, ha="center", va="center", fontsize=9)
        pos[t] = (8.55, y)

    ax.add_patch(FancyBboxPatch((2.55, 0.42), 5.9, 0.5, boxstyle="round,pad=0.03",
                                fc="#fff4cc", ec="k", ls="--"))
    ax.text(5.5, 0.67, "Deposit, Withdraw and Transfer funds  <<include>>  database triggers\n"
            "(audit trail, frozen-account guard, daily limit)", ha="center", va="center", fontsize=8)

    stick(ax, 1.1, 3.6, "Teller / Operator")
    stick(ax, 9.9, 3.6, "Administrator (DBA)")
    for t in left:
        ax.plot([1.45, pos[t][0]], [3.6, pos[t][1]], c="#444", lw=0.9)
    for t in right:
        ax.plot([9.55, pos[t][0]], [3.6, pos[t][1]], c="#444", lw=0.9)
    fig.savefig(f"{OUT}/usecase.png", bbox_inches="tight", facecolor="white")
    plt.close(fig)

# ------------------------------------------------------------------ sequence
def sequence():
    names = ["Operator", "app.py\n(terminal)", "transfer_funds()\nprocedure",
             "accounts /\ntransactions", "Triggers"]
    xs = [1.0, 3.4, 6.0, 8.6, 11.0]
    fig, ax = plt.subplots(figsize=(12.5, 8.6), dpi=170)
    ax.set_xlim(0, 12.2); ax.set_ylim(0, 8.6); ax.axis("off")
    top = 8.0
    for x, n in zip(xs, names):
        ax.add_patch(FancyBboxPatch((x - 0.85, top), 1.7, 0.55, boxstyle="round,pad=0.03",
                                    fc="#e3f2fd", ec="k"))
        ax.text(x, top + 0.275, n, ha="center", va="center", fontsize=8.5, fontweight="bold")
        ax.plot([x, x], [top, 0.25], c="#888", lw=1, ls=(0, (5, 4)))

    msgs = [
        (0, 1, "1: choose 'Transfer', enter from / to / amount", False),
        (1, 2, "2: CALL transfer_funds(from, to, amt)   [BEGIN is implicit]", False),
        (2, 3, "3: SELECT ... ORDER BY account_id FOR UPDATE  (lock both rows)", False),
        (2, 2, "4: validate: accounts ACTIVE, balance >= amount", False),
        (2, 3, "5: INSERT INTO transactions", False),
        (3, 4, "6: BEFORE INSERT -> daily-limit check (BK004 if exceeded)", False),
        (2, 3, "7: UPDATE accounts: debit sender, credit receiver", False),
        (3, 4, "8: BEFORE guard (BK001) / AFTER audit row written", False),
        (2, 1, "9: return OK   or   RAISE EXCEPTION (message)", True),
        (1, 3, "10: COMMIT  (or ROLLBACK on error - nothing partial survives)", False),
        (1, 0, "11: show '[OK] Transferred ...' or '[X] Rejected: reason'", True),
    ]
    y = 7.55
    for a, b, text, dashed in msgs:
        xa, xb = xs[a], xs[b]
        ls = "--" if dashed else "-"
        if a == b:
            ax.plot([xa, xa + 0.7, xa + 0.7, xa], [y, y, y - 0.28, y - 0.28], c="k", lw=1.2)
            ax.annotate("", xy=(xa, y - 0.28), xytext=(xa + 0.2, y - 0.28),
                        arrowprops=dict(arrowstyle="->", lw=1.2))
            ax.text(xa + 0.85, y - 0.14, text, fontsize=8, va="center")
            y -= 0.72
            continue
        ax.annotate("", xy=(xb, y), xytext=(xa, y),
                    arrowprops=dict(arrowstyle="->", lw=1.3, ls=ls))
        ax.text((xa + xb) / 2, y + 0.09, text, ha="center", va="bottom", fontsize=8)
        y -= 0.62
    fig.savefig(f"{OUT}/sequence.png", bbox_inches="tight", facecolor="white")
    plt.close(fig)

usecase(); sequence(); print("ok")
