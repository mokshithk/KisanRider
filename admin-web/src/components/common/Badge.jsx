import React from 'react';

const statusStyles = {
  // Positive / Active / Completed
  ACTIVE: 'bg-emerald-50 text-emerald-800 border-emerald-200',
  DELIVERED: 'bg-emerald-50 text-emerald-800 border-emerald-200',
  COMPLETED: 'bg-emerald-50 text-emerald-800 border-emerald-200',
  PAID: 'bg-emerald-50 text-emerald-800 border-emerald-200',
  OPEN: 'bg-emerald-50 text-emerald-800 border-emerald-200',
  APPROVED: 'bg-emerald-50 text-emerald-800 border-emerald-200',
  ACCEPTED: 'bg-emerald-50 text-emerald-800 border-emerald-200',
  LIVE: 'bg-emerald-50 text-emerald-800 border-emerald-200',
  ON_DUTY: 'bg-emerald-50 text-emerald-800 border-emerald-200',

  // Pending / In Transit / Warning
  PENDING: 'bg-amber-50 text-amber-800 border-amber-200',
  IN_PROGRESS: 'bg-sky-50 text-sky-800 border-sky-200',
  IN_TRANSIT: 'bg-sky-50 text-sky-800 border-sky-200',
  DRIVER_ASSIGNED: 'bg-indigo-50 text-indigo-800 border-indigo-200',
  LOCKED: 'bg-purple-50 text-purple-800 border-purple-200',
  OFF_DUTY: 'bg-slate-100 text-slate-700 border-slate-200',
  MOCK: 'bg-amber-50 text-amber-800 border-amber-200',

  // Negative / Cancelled / Suspended
  SUSPENDED: 'bg-rose-50 text-rose-800 border-rose-200',
  CANCELLED: 'bg-rose-50 text-rose-800 border-rose-200',
  REJECTED: 'bg-rose-50 text-rose-800 border-rose-200',
};

export default function Badge({ status, text }) {
  const normalized = (status || '').toUpperCase().replace(/\s+/g, '_');
  const style = statusStyles[normalized] || 'bg-slate-100 text-slate-700 border-slate-200';

  return (
    <span
      className={`inline-flex items-center px-2 py-0.5 rounded text-xs font-medium border ${style}`}
    >
      {text || status}
    </span>
  );
}
