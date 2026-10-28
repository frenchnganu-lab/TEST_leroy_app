import React, { useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import type { Cabinet, Project } from "./types";
import { demo } from "./demo";
import { Icon } from "./icons";
import "./style.css";

const format = (n: number) =>
  new Intl.NumberFormat("ru-RU", { maximumFractionDigits: 2 }).format(n);
const date = (value: string) =>
  new Intl.DateTimeFormat("ru-RU", {
    dateStyle: "medium",
    timeZone: "Asia/Krasnoyarsk",
  }).format(new Date(value));
const levels: Record<string, string> = {
  bronze: "Бронзовый",
  silver: "Серебряный",
  gold: "Золотой",
  platinum: "Платиновый",
};
const names: Record<string, string> = {
  project_share: "Вознаграждение за проект",
  project_bonus: "Бонус за закрытый проект",
  mention_bonus: "Рекламная отметка",
  event_bonus: "Участие в мероприятии",
  referral_bonus: "Приглашение дизайнера",
  welcome_bonus: "Приветственный подарок",
};
const statuses: Record<string, string> = {
  delivered: "Сдан клиенту",
  in_progress: "В работе",
  cancelled: "Отменён",
};
const tabs = [
  { label: "Главная", icon: "home" },
  { label: "Проекты", icon: "projects" },
  { label: "Отметки", icon: "mention" },
  { label: "Бонусы", icon: "bonus" },
  { label: "Профиль", icon: "profile" },
  { label: "Приглашённые", icon: "link" },
];

function Referrals({ data }: { data: Cabinet }) {
  const [message, setMessage] = useState("");
  const link = data.referral_url;
  const invited = data.referrals;
  async function copy() {
    if (!link) return;
    try {
      await navigator.clipboard.writeText(link);
      setMessage("Ссылка скопирована");
    } catch {
      setMessage("Выделите ссылку ниже и скопируйте вручную");
    }
  }
  return <section className="page referral-page">
    <span className="eyebrow gold">LEROY HOME CLUB</span>
    <h1>Приглашённые</h1>
    <p className="page-description">Дизайнеры, зарегистрированные и закреплённые за вами.</p>
    <div className="panel referral-total"><Icon name="clients" size={28} /><span>Ваши приглашённые</span><strong>{data.referral_count}</strong></div>
    {invited === undefined ? <div className="notice">Список пока недоступен. Обновите кабинет после обновления сервера.</div> : invited.length === 0 ?
      <Empty icon="clients" title="Пока никого нет" text="Здесь появятся дизайнеры после регистрации и закрепления приглашения за вами." /> :
      <ul className="panel invited-list">{invited.map(person => <li key={person.designer_id}>
        <span className="invited-avatar" aria-hidden="true">{person.full_name.trim().slice(0, 1)}</span>
        <div><strong>{person.full_name}</strong><small>{person.created_at ? `Регистрация: ${date(person.created_at)}` : "Регистрация подтверждена"}</small></div>
        <Icon name="check" size={20} />
      </li>)}</ul>}
    <div className="panel referral-link-card">
      <Icon name="link" /><h2>Ваша реферальная ссылка</h2>
      {link ? <>
        <label htmlFor="referral-url" className="small muted">Отправьте её дизайнеру</label>
        <input id="referral-url" readOnly value={link} onFocus={e => e.target.select()} />
        <div className="referral-actions"><button className="button gold-button" onClick={() => void copy()}>Копировать</button>
        <a className="button outline-button" target="_blank" rel="noopener noreferrer" href={`https://t.me/share/url?url=${encodeURIComponent(link)}`}>Поделиться</a></div>
      </> : <p>Приглашения по ссылке готовятся к запуску. Здесь появится ваша персональная ссылка.</p>}
      <p role="status" aria-live="polite">{message}</p>
    </div>
  </section>;
}

type MentionRequest = { request_id: string; publication_url: string; status: "pending" | "accepted" | "needs_revision"; review_comment: string | null; created_at: string };
function Mentions({ demoMode }: { demoMode: boolean }) {
  const [url, setUrl] = useState("");
  const [requests, setRequests] = useState<MentionRequest[]>([]);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(!demoMode);
  const [sending, setSending] = useState(false);
  const [ready, setReady] = useState(demoMode);
  const busy = useRef(false);
  const open = requests.find(r => r.status !== "accepted");
  const current = open || requests[0];
  async function api(method: string, body?: object) {
    const response = await fetch("/api/mentions", { method, cache: "no-store",
      headers: { Authorization: `tma ${window.Telegram?.WebApp.initData || ""}`, "Content-Type": "application/json" },
      body: body ? JSON.stringify(body) : undefined });
    const result = await response.json();
    if (!response.ok) throw new Error(typeof result.detail === "string" ? result.detail : "Не удалось загрузить отметки");
    return result;
  }
  async function refresh() {
    if (demoMode) return;
    setLoading(true);
    try { const result = await api("GET"); setRequests(result.requests); setReady(true); setError(""); }
    catch (e) { setReady(false); setError(e instanceof Error ? e.message : "Ошибка соединения"); }
    finally { setLoading(false); }
  }
  useEffect(() => { void refresh(); }, [demoMode]);
  async function submit(event: React.FormEvent) {
    event.preventDefault();
    if (busy.current || open || !ready) return;
    if (!/^https:\/\/(www\.)?instagram\.com\/(p|reel|tv)\/[A-Za-z0-9_-]+\/?([?#]\S*)?$/.test(url.trim())) {
      setError("Укажите ссылку Instagram на пост или Reels"); return;
    }
    busy.current = true; setSending(true); setError("");
    try {
      if (demoMode) {
        setRequests([{ request_id: "demo", publication_url: url.trim(), status: "pending", review_comment: null, created_at: new Date().toISOString() }, ...requests]);
      } else {
        const result = await api("POST", { publication_url: url.trim() });
        setRequests(old => [result.request, ...old.filter(r => r.request_id !== result.request.request_id)]);
      }
      setUrl("");
    } catch (e) { setError(e instanceof Error ? e.message : "Ошибка соединения"); if (!demoMode) setReady(false); }
    finally { busy.current = false; setSending(false); }
  }
  const label = (status: string) => status === "accepted" ? "Зачтено" : status === "needs_revision" ? "Нужна правка" : "В работе";
  return <section className="page mentions-page">
    <span className="eyebrow gold">LEROY HOME CLUB</span><h1>Отметки</h1>
    <p className="page-description">Отправьте публикацию с обзором LEROY. После проверки здесь появится результат.</p>
    {demoMode && <div className="notice">Демонстрация. Ссылки не сохраняются и не отправляются на проверку.</div>}
    {!demoMode && <button className="text-button" disabled={loading || sending} onClick={() => void refresh()}>{loading ? "Загрузка…" : "Обновить статус"}</button>}
    <form className="panel mention-form" onSubmit={e => void submit(e)}>
      <label htmlFor="mention-url">Ссылка на публикацию</label>
      <input id="mention-url" type="url" inputMode="url" placeholder="https://www.instagram.com/p/…" value={url} onChange={e => setUrl(e.target.value)} disabled={!!open || loading || sending || !ready} aria-describedby="mention-help" />
      <p id="mention-help" className="small">Следующая отправка доступна после зачтения предыдущей отметки.</p>
      <button className="button gold-button full" disabled={!!open || loading || sending || !ready} type="submit">{sending ? "Отправка…" : open ? "Ожидает проверки" : "Отправить на проверку"}</button>
    </form>
    {error && <p role="alert">{error}</p>}
    {current && <article className="panel mention-status" aria-live="polite">
      <span className={`badge ${current.status === "accepted" ? "delivered" : ""}`}>{label(current.status)}</span>
      <h2>{current.status === "accepted" ? "Публикация принята" : "Ваша публикация"}</h2>
      <a className="mention-address" href={current.publication_url} target="_blank" rel="noopener noreferrer">{current.publication_url}</a>
      <p className="small">{date(current.created_at)} · {current.request_id}</p>
      {current.review_comment && <p><strong>Комментарий проверяющего</strong><br />{current.review_comment}</p>}
      {current.status === "accepted" && <p>Начисление бонуса отображается в разделе «Бонусы».</p>}
    </article>}
    {demoMode && current && <div className="filters">{["pending", "accepted", "needs_revision"].map(status => <button key={status} onClick={() => setRequests(old => old.map(r => r.request_id === current.request_id ? {...r, status: status as MentionRequest["status"], review_comment: status === "needs_revision" ? "Пример: проверьте доступность публикации" : null} : r))}>{label(status)}</button>)}</div>}
    <h2 className="mention-history-title">Зачтённые отметки</h2>
    {requests.filter(r => r.status === "accepted").map(r => <article className="panel mention-status" key={r.request_id}><span className="badge delivered">Зачтено</span><p>{date(r.created_at)}</p><a className="mention-address" href={r.publication_url} target="_blank" rel="noopener noreferrer">{r.publication_url}</a></article>)}
    {!loading && ready && !requests.some(r => r.status === "accepted") && <Empty icon="mention" title="Пока нет зачтённых отметок" text="Здесь появятся публикации после подтверждения." />}
  </section>;
}

type Sheet =
  | "menu"
  | "notifications"
  | "balance"
  | "level"
  | "rules"
  | "referrals"
  | "events"
  | "project"
  | null;
function Empty({
  icon,
  title,
  text,
}: {
  icon: string;
  title: string;
  text: string;
}) {
  return (
    <div className="empty">
      <span className="empty-icon">
        <Icon name={icon} size={30} />
      </span>
      <h2>{title}</h2>
      <p>{text}</p>
    </div>
  );
}
function Modal({
  title,
  children,
  onClose,
}: {
  title: string;
  children: React.ReactNode;
  onClose: () => void;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const el = ref.current;
    el?.showModal();
    const prev = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      el?.close();
      document.body.style.overflow = prev;
    };
  }, []);
  return (
    <dialog
      ref={ref}
      className="sheet"
      aria-labelledby="sheet-title"
      onCancel={onClose}
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <div className="sheet-inner">
        <div className="sheet-head">
          <h2 id="sheet-title">{title}</h2>
          <button
            className="icon-button"
            aria-label="Закрыть окно"
            onClick={onClose}
          >
            <Icon name="close" />
          </button>
        </div>
        {children}
      </div>
    </dialog>
  );
}
function App() {
  const [data, setData] = useState<Cabinet | null>(null),
    [error, setError] = useState(""),
    [loading, setLoading] = useState(true),
    [canDemo, setCanDemo] = useState(false),
    [isDemo, setIsDemo] = useState(false);
  const [tab, setTab] = useState("Главная"),
    [sheet, setSheet] = useState<Sheet>(null),
    [project, setProject] = useState<Project | null>(null),
    [filter, setFilter] = useState("all"),
    [operationFilter, setOperationFilter] = useState("all");
  const abort = useRef<AbortController | null>(null);
  async function load() {
    abort.current?.abort();
    const controller = new AbortController();
    abort.current = controller;
    setLoading(true);
    setError("");
    setData(null);
    setIsDemo(false);
    setSheet(null);
    setCanDemo(false);
    try {
      const tg = window.Telegram?.WebApp;
      tg?.ready();
      tg?.expand();
      // Color APIs depend on Telegram client version; their failure must not block login.
      try {
        tg?.setHeaderColor?.("#101110");
        tg?.setBackgroundColor?.("#101110");
      } catch {
        /* older client */
      }
      const configResponse = await fetch("/api/config", {
        signal: controller.signal,
        cache: "no-store",
      });
      if (!configResponse.ok)
        throw new Error("Не удалось подключиться. Попробуйте ещё раз.");
      const config = await configResponse.json();
      setCanDemo(config.demo_available === true);
      if (!tg?.initData)
        throw new Error("Откройте личный кабинет через бота LEROY в Telegram.");
      const response = await fetch("/api/cabinet", {
        headers: { Authorization: `tma ${tg.initData}` },
        cache: "no-store",
        signal: controller.signal,
      });
      const body = await response.json();
      if (!response.ok)
        throw new Error(
          typeof body.detail === "string"
            ? body.detail
            : "Не удалось загрузить кабинет",
        );
      setData(body);
    } catch (e) {
      if (!controller.signal.aborted)
        setError(
          e instanceof Error ? e.message : "Не удалось загрузить данные",
        );
    } finally {
      if (!controller.signal.aborted) setLoading(false);
    }
  }
  useEffect(() => {
    void load();
    return () => abort.current?.abort();
  }, []);
  function navigate(next: string) {
    setTab(next);
    setSheet(null);
    window.scrollTo({ top: 0, behavior: "instant" });
  }
  const openDemo = () => {
    setData(demo);
    setIsDemo(true);
    setError("");
    setTab("Главная");
  };
  const projects =
    data?.projects.filter((p) => filter === "all" || p.status === filter) || [];
  const operations =
    data?.operations.filter(
      (o) => operationFilter === "all" || o.currency === operationFilter,
    ) || [];
  const loyalty = data?.loyalty;
  const progress = loyalty
    ? Math.min(
        100,
        Math.max(0, (loyalty.weight / loyalty.next_threshold) * 100),
      )
    : 0;
  const titles: Record<NonNullable<Sheet>, string> = {
    menu: "Клуб LEROY",
    notifications: "Уведомления",
    balance: "О ваших начислениях",
    level: "Ваш статус",
    rules: "Программа привилегий",
    referrals: "Приглашения",
    events: "События клуба",
    project: "Карточка проекта",
  };
  return (
    <div className="app-shell">
      <header className="header">
        <button
          className="icon-button gold"
          aria-label="Открыть меню"
          onClick={() => setSheet("menu")}
        >
          <Icon name="menu" size={27} />
        </button>
        <a
          className="brand"
          href="/"
          aria-label="LEROY Home Club — главная"
          onClick={(e) => {
            if (data) {
              e.preventDefault();
              navigate("Главная");
            }
          }}
        >
          LEROY<span>HOME CLUB</span>
        </a>
        <button
          className="icon-button gold"
          aria-label="Уведомления"
          onClick={() => setSheet("notifications")}
        >
          <Icon name="bell" size={25} />
        </button>
      </header>
      {!data ? (
        <main className="welcome">
          <div className="welcome-photo" />
          <div className="welcome-copy">
            <span className="eyebrow gold">ДЛЯ ТЕХ, КТО СОЗДАЁТ</span>
            <h1>
              Ваше пространство
              <br />в LEROY.
            </h1>
            <p>
              Проекты, вознаграждения и новые возможности для вашего творчества.
            </p>
          </div>
          <section className="panel login-panel" aria-live="polite">
            {loading ? (
              <>
                <h2>Открываем кабинет</h2>
                <div className="skeleton wide" />
                <div className="skeleton short" />
              </>
            ) : (
              <>
                <h2>Добро пожаловать в клуб</h2>
                <p>{error}</p>
                <div className="login-actions">
                  {canDemo && (
                    <button className="button gold-button" onClick={openDemo}>
                      Посмотреть демо <Icon name="arrow" size={18} />
                    </button>
                  )}
                  <button
                    className="button outline-button"
                    onClick={() => void load()}
                  >
                    Повторить вход
                  </button>
                </div>
              </>
            )}
          </section>
        </main>
      ) : (
        <>
          <div className="mode-label">
            <span className="status-dot" />
            {isDemo ? "Демо · вымышленные данные" : "Тестовый кабинет"}
            <span className="mode-right">LEROY HOME CLUB</span>
          </div>
          <main id="main-content">
            {tab === "Главная" && (
              <>
                <section className="balance-hero">
                  <div className="hero-photo" />
                  <div className="hero-content">
                    <div className="hero-label">
                      Ваши бонусы{" "}
                      <button
                        className="inline-icon"
                        aria-label="Как устроен баланс"
                        onClick={() => setSheet("balance")}
                      >
                        <Icon name="info" size={16} />
                      </button>
                    </div>
                    <div className="balance-number">
                      {format(data.balance.bonus_lr)}
                      <span className="coin" aria-label="LR">
                        L
                      </span>
                    </div>
                    <div className="balance-unit">LR · всего начислено</div>
                    <p className="exchange gold">
                      {data.rub_per_lr && data.rub_per_lr > 0 ? (
                        <>
                          1 LR = {format(data.rub_per_lr)} ₽
                          <span>
                            Эквивалент{" "}
                            {format(data.balance.bonus_lr * data.rub_per_lr)} ₽
                          </span>
                        </>
                      ) : (
                        <>Курс уточняется</>
                      )}
                    </p>
                    <button
                      className="button gold-button"
                      onClick={() => {
                        setOperationFilter("all");
                        navigate("Бонусы");
                      }}
                    >
                      История операций <Icon name="arrow" size={19} />
                    </button>
                  </div>
                </section>
                <button
                  className="commission-line"
                  onClick={() => {
                    setOperationFilter("RUB");
                    navigate("Бонусы");
                  }}
                >
                  <span className="commission-symbol">
                    <Icon name="ruble" size={20} />
                  </span>
                  <span>
                    Вознаграждение за проекты<small>Всего начислено</small>
                  </span>
                  <strong>{format(data.balance.commission_rub)} ₽</strong>
                  <Icon name="chevron" size={16} />
                </button>
                <section className="status-card panel">
                  <div className="status-main">
                    <span className="muted">Мой статус</span>
                    <button
                      className="level-name"
                      onClick={() => setSheet("level")}
                    >
                      <span>
                        {levels[data.designer.level_code] ||
                          data.designer.level_code}
                      </span>
                      <span className="gem">
                        <Icon name="diamond" size={35} />
                      </span>
                    </button>
                    {data.designer.level_code === "platinum" ? (
                      <p className="status-caption">
                        Максимальный уровень клуба
                      </p>
                    ) : loyalty ? (
                      <>
                        <p className="status-caption">
                          До следующего статуса —{" "}
                          {format(
                            Math.max(
                              0,
                              loyalty.next_threshold - loyalty.weight,
                            ),
                          )}{" "}
                          весов
                        </p>
                        <div
                          className="progress"
                          role="progressbar"
                          aria-label="Прогресс уровня"
                          aria-valuenow={Math.round(progress)}
                          aria-valuemin={0}
                          aria-valuemax={100}
                        >
                          <span style={{ width: `${progress}%` }} />
                        </div>
                        <small className="period">{loyalty.period}</small>
                      </>
                    ) : (
                      <p className="status-caption">
                        Прогресс появится после подключения весов
                      </p>
                    )}
                  </div>
                  <div className="status-features">
                    <span>
                      <Icon name="bonus" size={18} />
                      Бонусы за активность
                    </span>
                    <span>
                      <Icon name="projects" size={18} />
                      Вознаграждение за проекты
                    </span>
                    <button onClick={() => setSheet("level")}>
                      <Icon name="shield" size={18} />
                      Условия уровня <Icon name="chevron" size={13} />
                    </button>
                  </div>
                </section>
                <section className="projects-summary">
                  <div className="section-title">
                    <h2>Мои проекты</h2>
                    <button
                      className="text-button"
                      onClick={() => {
                        setFilter("all");
                        navigate("Проекты");
                      }}
                    >
                      Смотреть все <Icon name="chevron" size={15} />
                    </button>
                  </div>
                  <div className="stats-grid">
                    <button
                      className="stat-card"
                      onClick={() => {
                        setFilter("in_progress");
                        navigate("Проекты");
                      }}
                    >
                      <span className="stat-icon">
                        <Icon name="projects" />
                      </span>
                      <strong>{data.project_summary.active}</strong>
                      <span>в работе</span>
                    </button>
                    <button
                      className="stat-card"
                      onClick={() => {
                        setFilter("delivered");
                        navigate("Проекты");
                      }}
                    >
                      <span className="stat-icon">
                        <Icon name="check" />
                      </span>
                      <strong>{data.project_summary.delivered}</strong>
                      <span>завершено</span>
                    </button>
                    <button
                      className="stat-card"
                      onClick={() => {
                        setFilter("all");
                        navigate("Проекты");
                      }}
                    >
                      <span className="stat-icon">
                        <Icon name="ruble" />
                      </span>
                      <strong className="stat-amount">
                        {format(data.project_summary.total_amount_rub)} ₽
                      </strong>
                      <span>
                        сумма заказов<small>без отменённых</small>
                      </span>
                    </button>
                  </div>
                </section>
                <button
                  className="club-banner"
                  onClick={() => setSheet("rules")}
                >
                  <span className="banner-content">
                    <span className="eyebrow">БОЛЬШЕ ВОЗМОЖНОСТЕЙ</span>
                    <strong>
                      Создавайте.
                      <br />
                      Вдохновляйте.
                      <br />
                      Получайте больше.
                    </strong>
                    <span className="banner-description">
                      Узнайте, как устроены
                      <br />
                      привилегии клуба LEROY.
                    </span>
                    <span className="banner-cta">
                      Подробнее <Icon name="arrow" size={16} />
                    </span>
                  </span>
                  <span className="banner-image" />
                </button>
                <button
                  className="events-line"
                  onClick={() => setSheet("events")}
                >
                  <span>События и новости клуба</span>
                  <Icon name="chevron" size={17} />
                </button>
              </>
            )}
            {tab === "Проекты" && (
              <section className="page">
                <span className="eyebrow gold">ОТ ИДЕИ ДО РЕАЛИЗАЦИИ</span>
                <h1>Мои проекты</h1>
                <p className="page-description">
                  Всего {data.project_summary.total} · в списке последние 30
                </p>
                <div className="filters" aria-label="Фильтры проектов">
                  {[
                    ["all", "Все"],
                    ["in_progress", "В работе"],
                    ["delivered", "Завершены"],
                    ["cancelled", "Отменены"],
                  ].map(([v, t]) => (
                    <button
                      key={v}
                      className={filter === v ? "selected" : ""}
                      aria-pressed={filter === v}
                      onClick={() => setFilter(v)}
                    >
                      {t}
                    </button>
                  ))}
                </div>
                <div className="project-list">
                  {projects.length ? (
                    projects.map((p) => (
                      <button
                        className="project-card panel"
                        key={p.order_number}
                        onClick={() => {
                          setProject(p);
                          setSheet("project");
                        }}
                      >
                        <div className="project-top">
                          <span className="stat-icon">
                            <Icon name="projects" />
                          </span>
                          <span className={`badge ${p.status}`}>
                            {statuses[p.status] || p.status}
                          </span>
                        </div>
                        <h2>Заказ {p.order_number}</h2>
                        <div className="project-bottom">
                          <strong>{format(p.amount_rub)} ₽</strong>
                          <span>
                            Подробнее <Icon name="chevron" size={14} />
                          </span>
                        </div>
                      </button>
                    ))
                  ) : (
                    <Empty
                      icon="projects"
                      title="Здесь пока нет проектов"
                      text="Заказы появятся после добавления менеджером. Можно выбрать другой фильтр."
                    />
                  )}
                </div>
              </section>
            )}
            {tab === "Клиенты" && (
              <section className="page">
                <span className="eyebrow gold">ВАШИ ЗАКАЗЧИКИ</span>
                <h1>Клиенты</h1>
                <section className="panel">
                  <Empty
                    icon="clients"
                    title="Раздел готовится"
                    text="Здесь появятся закреплённые за вами клиенты и их проекты."
                  />
                </section>
              </section>
            )}
            {tab === "Бонусы" && (
              <section className="page">
                <span className="eyebrow gold">ПРОЗРАЧНО В КАЖДОЙ ДЕТАЛИ</span>
                <h1>Бонусы и начисления</h1>
                <div className="mini-balances">
                  <div className="panel">
                    <small>Бонусы</small>
                    <strong>
                      {format(data.balance.bonus_lr)} <em>LR</em>
                    </strong>
                  </div>
                  <div className="panel">
                    <small>Вознаграждение</small>
                    <strong>
                      {format(data.balance.commission_rub)} <em>₽</em>
                    </strong>
                  </div>
                </div>
                <button
                  className="text-button rules-button"
                  onClick={() => setSheet("balance")}
                >
                  О балансе и курсе <Icon name="info" size={15} />
                </button>
                <div className="section-title">
                  <h2>История операций</h2>
                  <span className="muted small">Последние 30</span>
                </div>
                <div className="filters" aria-label="Фильтры операций">
                  {[
                    ["all", "Все"],
                    ["LR", "Бонусы LR"],
                    ["RUB", "Вознаграждение ₽"],
                  ].map(([v, t]) => (
                    <button
                      key={v}
                      className={operationFilter === v ? "selected" : ""}
                      aria-pressed={operationFilter === v}
                      onClick={() => setOperationFilter(v)}
                    >
                      {t}
                    </button>
                  ))}
                </div>
                <div className="panel operations">
                  {operations.length ? (
                    operations.map((o, i) => (
                      <article
                        className="operation"
                        key={`${o.event_at}-${o.operation_type}-${i}`}
                      >
                        <span className="operation-icon">
                          <Icon
                            name={o.currency === "RUB" ? "ruble" : "gift"}
                            size={20}
                          />
                        </span>
                        <div>
                          <strong>
                            {names[o.operation_type] || o.operation_type}
                          </strong>
                          <small>
                            {date(o.event_at)}
                            {o.order_number ? ` · ${o.order_number}` : ""}
                          </small>
                        </div>
                        <b>
                          +{format(o.amount)}
                          <small>{o.currency === "RUB" ? "₽" : "LR"}</small>
                        </b>
                      </article>
                    ))
                  ) : (
                    <Empty
                      icon="history"
                      title="Начислений пока нет"
                      text="Здесь будет история подтверждённых операций."
                    />
                  )}
                </div>
                <p className="footnote">
                  Даты указаны по времени Красноярска. Выплаты и конвертация
                  пока недоступны.
                </p>
              </section>
            )}
            {tab === "Профиль" && (
              <section className="page">
                <span className="eyebrow gold">УЧАСТНИК КЛУБА LEROY</span>
                <h1>Мой профиль</h1>
                <div className="panel profile-card">
                  <span className="avatar">
                    {data.designer.full_name
                      .split(" ")
                      .slice(0, 2)
                      .map((s) => s[0])
                      .join("")}
                  </span>
                  <h2>{data.designer.full_name}</h2>
                  <span className="badge">
                    {levels[data.designer.level_code] ||
                      data.designer.level_code}
                  </span>
                  <dl className="details">
                    <div>
                      <dt>ID дизайнера</dt>
                      <dd>{data.designer.designer_id}</dd>
                    </div>
                    <div>
                      <dt>Вход через Telegram</dt>
                      <dd>{isDemo ? "Демонстрация" : "Подтверждён"}</dd>
                    </div>
                  </dl>
                </div>
                <div className="panel profile-links">
                  <button onClick={() => navigate("Приглашённые")}>
                    <Icon name="clients" />
                    <span>
                      Пригласить дизайнера
                      <small>Приглашено: {data.referral_count}</small>
                    </span>
                    <Icon name="chevron" size={18} />
                  </button>
                  <button onClick={() => setSheet("level")}>
                    <Icon name="shield" />
                    <span>Мой уровень</span>
                    <Icon name="chevron" size={18} />
                  </button>
                  <button onClick={() => setSheet("rules")}>
                    <Icon name="bonus" />
                    <span>Правила программы</span>
                    <Icon name="chevron" size={18} />
                  </button>
                </div>
                {isDemo && (
                  <button
                    className="button outline-button full"
                    onClick={() => void load()}
                  >
                    Выйти из демо
                  </button>
                )}
              </section>
            )}
            {tab === "Отметки" && <Mentions demoMode={isDemo} />}
            {tab === "Приглашённые" && <Referrals data={data} />}
          </main>
          <nav className="bottom-nav" aria-label="Основная навигация">
            {tabs.map((t) => (
              <button
                key={t.label}
                aria-current={tab === t.label ? "page" : undefined}
                className={tab === t.label ? "active" : ""}
                onClick={() => navigate(t.label)}
              >
                <Icon name={t.icon} size={23} />
                <span>{t.label}</span>
              </button>
            ))}
          </nav>
        </>
      )}
      {sheet && (
        <Modal title={titles[sheet]} onClose={() => setSheet(null)}>
          {sheet === "menu" && (
            <div className="menu-list">
              {data &&
                [...tabs, { label: "Клиенты", icon: "clients" }].map((t) => (
                  <button key={t.label} onClick={() => navigate(t.label)}>
                    <Icon name={t.icon} />
                    {t.label}
                    <Icon name="chevron" size={16} />
                  </button>
                ))}
              <button onClick={() => setSheet("rules")}>
                <Icon name="shield" />
                Программа привилегий
                <Icon name="chevron" size={16} />
              </button>
              <button onClick={() => setSheet("events")}>
                <Icon name="bell" />
                События клуба
                <Icon name="chevron" size={16} />
              </button>
            </div>
          )}
          {sheet === "notifications" && (
            <Empty
              icon="bell"
              title="Новых уведомлений нет"
              text="Здесь появятся новости клуба и сообщения о ваших проектах."
            />
          )}
          {sheet === "events" && (
            <Empty
              icon="gift"
              title="Скоро новые встречи"
              text="Опубликованных событий пока нет. Анонсы мероприятий и акций появятся здесь."
            />
          )}
          {sheet === "balance" && (
            <div className="prose">
              <p>
                <strong>Вознаграждение в рублях</strong> — начисленный процент
                от суммы проекта. <strong>LR</strong> — отдельная бонусная
                валюта за проекты и активности.
              </p>
              <p>
                {data?.rub_per_lr
                  ? `Текущий курс: 1 LR = ${format(data.rub_per_lr)} ₽. ${data.rub_per_lr === 0.2 ? "Это 5 LR за 1 ₽." : ""}`
                  : "В тестовой модели 5 LR = 1 ₽."}
              </p>
              <p>
                Сейчас показываем всего начисленное. Денежный эквивалент бонусов
                не означает, что эта сумма уже доступна для вывода. Выплаты,
                списания и конвертация будут подключены отдельно.
              </p>
              <p>Вес уровня учитывается отдельно от LR.</p>
            </div>
          )}
          {sheet === "level" && data && (
            <div className="prose">
              <div className="level-modal">
                <Icon name="diamond" size={48} />
                <strong>
                  {levels[data.designer.level_code] || data.designer.level_code}
                </strong>
              </div>
              {loyalty ? (
                <>
                  <p>
                    Зачтено <strong>{format(loyalty.weight)} весов</strong>.
                    Следующий уровень —{" "}
                    {levels[loyalty.next_level]?.toLowerCase()}.
                  </p>
                  <p>
                    Период: {loyalty.period}.
                    {isDemo ? " Это пример прогресса для демонстрации." : ""}
                  </p>
                </>
              ) : (
                <p>
                  {data.designer.level_code === "platinum"
                    ? "Вы на максимальном уровне клуба."
                    : "Подсчёт весов ещё не подключён к кабинету. Текущий статус получен из вашей карточки."}
                </p>
              )}
              <p>
                Веса отражают участие в программе и достижения. Они учитываются
                отдельно от суммы бонусов LR.
              </p>
              <div className="level-ladder">
                {[
                  ["Бронзовый", "Стартовый"],
                  ["Серебряный", "500 весов"],
                  ["Золотой", "2 000 весов"],
                  ["Платиновый", "5 000 весов"],
                ].map(([n, v]) => (
                  <div key={n}>
                    <span>{n}</span>
                    <strong>{v}</strong>
                  </div>
                ))}
              </div>
              <p className="footnote">
                Пороги тестовой модели. Автоматическое повышение и период зачёта
                проверим до рабочего запуска.
              </p>
            </div>
          )}
          {sheet === "rules" && (
            <div className="prose">
              <p className="muted">Условия тестовой программы</p>
              <div className="rule">
                <Icon name="projects" />
                <div>
                  <h3>За реализованные проекты</h3>
                  <p>
                    Денежное вознаграждение зависит от уровня. Бонус за закрытый
                    проект — 10% его суммы в эквиваленте LR.
                  </p>
                </div>
              </div>
              <div className="rule">
                <Icon name="gift" />
                <div>
                  <h3>За участие и рекомендации</h3>
                  <p>
                    Рекламная отметка и участие в мероприятии — по 2 000 ₽ в
                    эквиваленте LR за подтверждённое событие.
                  </p>
                </div>
              </div>
              <div className="rule">
                <Icon name="clients" />
                <div>
                  <h3>За приглашённого дизайнера</h3>
                  <p>
                    Предусмотрено 10% от суммы его первого сданного проекта в
                    эквиваленте LR. Автоматическое начисление ещё не подключено.
                  </p>
                </div>
              </div>
              <p className="footnote">
                Иллюстрация интерьера создана для демонстрации и не является
                фотографией выполненного проекта LEROY.
              </p>
            </div>
          )}
          {sheet === "referrals" && data && <Referrals data={data} />}
          {sheet === "project" && project && (
            <>
              <span className={`badge ${project.status}`}>
                {statuses[project.status] || project.status}
              </span>
              <dl className="details">
                <div>
                  <dt>Номер заказа</dt>
                  <dd>{project.order_number}</dd>
                </div>
                <div>
                  <dt>Сумма</dt>
                  <dd>{format(project.amount_rub)} ₽</dd>
                </div>
                {project.delivered_at && (
                  <div>
                    <dt>Дата сдачи</dt>
                    <dd>{date(project.delivered_at)}</dd>
                  </div>
                )}
              </dl>
              <p className="footnote">
                Этапы производства появятся после подключения Битрикса.
              </p>
            </>
          )}
        </Modal>
      )}
    </div>
  );
}
createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);



