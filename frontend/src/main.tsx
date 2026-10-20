import React, { useEffect, useState } from 'react';
import { createRoot } from 'react-dom/client';
import type { Cabinet } from './types';
import { demo } from './demo';
import './style.css';
const money = (n: number) => new Intl.NumberFormat('ru-RU', { maximumFractionDigits: 2 }).format(n);
const levels: Record<string,string> = { bronze: 'Бронзовый', silver: 'Серебряный', gold: 'Золотой', platinum: 'Платиновый' };
const names: Record<string,string> = { project_share: 'Вознаграждение за проект', project_bonus: 'Бонус за закрытый проект', mention_bonus: 'Рекламная отметка', event_bonus: 'Участие в мероприятии', referral_bonus: 'Приглашение дизайнера', welcome_bonus: 'Приветственный подарок' };
const statuses: Record<string,string> = { delivered: 'Сдан клиенту', in_progress: 'В работе', cancelled: 'Отменён' };
function App() {
  const [data, setData] = useState<Cabinet | null>(null);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);
  const [canDemo, setCanDemo] = useState(false);
  const [isDemo, setIsDemo] = useState(false);
  const [tab, setTab] = useState('Обзор');
  async function load() {
    setLoading(true); setError(''); setData(null); setIsDemo(false);
    try {
      const tg = window.Telegram?.WebApp;
      tg?.ready(); tg?.expand();
      const config = await fetch('/api/config').then(r => { if (!r.ok) throw new Error('Сервер недоступен'); return r.json(); });
      setCanDemo(config.demo_available === true);
      if (!tg?.initData) throw new Error('Откройте кабинет через Telegram. Для просмотра макета доступен демонстрационный режим, если он включён на сервере.');
      const response = await fetch('/api/cabinet', { headers: { Authorization: `tma ${tg.initData}` }, cache: 'no-store' });
      const body = await response.json();
      if (!response.ok) throw new Error(typeof body.detail === 'string' ? body.detail : 'Не удалось открыть кабинет');
      setData(body);
    } catch (e) { setError(e instanceof Error ? e.message : 'Не удалось загрузить данные'); }
    finally { setLoading(false); }
  }
  useEffect(() => { void load(); }, []);
  const demoOpen = () => { setData(demo); setIsDemo(true); setError(''); };
  return <div className="shell"><header><a className="brand" href="/">LEROY<span>HOME · DESIGNER CLUB</span></a><span className="edition">Личный кабинет</span></header>
    {!data ? <main className="welcome"><span className="eyebrow">ПАРТНЁРСТВО В ДЕТАЛЯХ</span><h1>Пространство<br/>ваших возможностей.</h1><p>Проекты, вознаграждения и привилегии — в одном кабинете.</p><section className="state" aria-live="polite"><h2>{loading ? 'Открываем кабинет…' : 'Вход в клуб'}</h2><p>{error || 'Проверяем вход через Telegram'}</p>{!loading && <div className="actions"><button onClick={() => void load()}>Повторить вход</button>{canDemo && <button className="secondary" onClick={demoOpen}>Посмотреть демо</button>}</div>}</section></main> : <main>
      <div className="test-strip">{isDemo ? 'Демонстрация · вымышленные данные' : 'Тестовый кабинет · данные SQL'} · Выплаты не подключены</div>
      <section className="greeting"><div><span className="eyebrow">ВАШЕ ПАРТНЁРСТВО С LEROY</span><h1>Здравствуйте,<br/>{data.designer.full_name.split(' ')[0]}.</h1><p>Создавайте интерьеры. Мы позаботимся о деталях.</p></div><div className="membership"><span className="emblem">L</span><span>Уровень партнёра<strong>{levels[data.designer.level_code] || data.designer.level_code}</strong><small>{data.designer.designer_id}</small></span></div></section>
      <nav aria-label="Разделы кабинета">{['Обзор','Проекты','Операции','Приглашения'].map(t => <button key={t} className={tab===t?'active':''} onClick={() => setTab(t)}>{t}</button>)}</nav>
      {tab==='Обзор' && <><section className="balances"><article className="card dark"><span className="eyebrow">ДЕНЕЖНОЕ ВОЗНАГРАЖДЕНИЕ</span><div className="amount">{money(data.balance.commission_rub)} <small>₽</small></div><p>Всего начислено за проекты</p><span className="note">Вывод средств появится позже</span></article><article className="card"><span className="eyebrow">ВАШИ БОНУСЫ</span><div className="amount">{money(data.balance.bonus_lr)} <small>LR</small></div><p>Внутренняя валюта клуба</p><span className="note">Конвертация появится после проверки правил</span></article></section><section className="overview"><article className="card"><span className="eyebrow">ПРОЕКТЫ</span><h2>Каждый проект —<br/>часть вашей истории.</h2><p>В списке: {data.projects.length}. Последние 30 проектов.</p><button className="text-button" onClick={() => setTab('Проекты')}>Посмотреть проекты ↗</button></article><article className="card sand"><span className="eyebrow">КРУГ ЕДИНОМЫШЛЕННИКОВ</span><h2>Приглашайте<br/>талантливых коллег.</h2><p>К вам привязано дизайнеров: {data.referral_count}</p><button className="text-button" onClick={() => setTab('Приглашения')}>О программе ↗</button></article></section></>}
      {tab==='Проекты' && <section className="card"><h2>Ваши проекты</h2><p>Последние 30 записей</p><div className="list">{data.projects.length ? data.projects.map(p => <article className="list-row" key={p.order_number}><div><strong>{p.order_number}</strong><small>{statuses[p.status] || p.status}</small></div><b>{money(p.amount_rub)} ₽</b></article>) : <p>Проектов пока нет.</p>}</div></section>}
      {tab==='Операции' && <section className="card"><h2>История начислений</h2><p>Последние 30 операций · время Красноярска</p><div className="list">{data.operations.length ? data.operations.map((o,i) => <article className="list-row" key={i}><div><strong>{names[o.operation_type] || o.operation_type}</strong><small>{new Intl.DateTimeFormat('ru-RU',{dateStyle:'medium',timeZone:'Asia/Krasnoyarsk'}).format(new Date(o.event_at))}</small></div><b>+{money(o.amount)} {o.currency==='RUB'?'₽':'LR'}</b></article>) : <p>Начислений пока нет.</p>}</div></section>}
      {tab==='Приглашения' && <section className="card referral"><span className="eyebrow">РАСТЁМ ВМЕСТЕ</span><h2>Сильное партнёрство<br/>начинается с рекомендации.</h2><p>Приглашённых дизайнеров: <strong>{data.referral_count}</strong></p><p>По согласованной модели бонус — 10% суммы первого сданного проекта приглашённого дизайнера, с начислением в LR.</p><div className="notice">Персональная ссылка и автоматическое начисление за рефералов ещё не подключены.</div></section>}
      <footer><span>LEROY HOME</span><span>Создаём пространство для партнёрства</span>{isDemo && <button className="text-button" onClick={() => void load()}>Выйти из демо</button>}</footer>
    </main>}</div>;
}
createRoot(document.getElementById('root')!).render(<React.StrictMode><App/></React.StrictMode>);
