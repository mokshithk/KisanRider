import React from 'react';

const statusConfig = {
  // Positive / Active / Completed
  ACTIVE: {
    style: 'bg-emerald-50 text-emerald-800 border-emerald-200/80',
    dot: 'bg-emerald-500',
  },
  DELIVERED: {
    style: 'bg-emerald-50 text-emerald-800 border-emerald-200/80',
    dot: 'bg-emerald-500',
  },
  COMPLETED: {
    style: 'bg-emerald-50 text-emerald-800 border-emerald-200/80',
    dot: 'bg-emerald-500',
  },
  PAID: {
    style: 'bg-emerald-50 text-emerald-800 border-emerald-200/80',
    dot: 'bg-emerald-500',
  },
  APPROVED: {
    style: 'bg-emerald-50 text-emerald-800 border-emerald-200/80',
    dot: 'bg-emerald-500',
  },
  ACCEPTED: {
    style: 'bg-emerald-50 text-emerald-800 border-emerald-200/80',
    dot: 'bg-emerald-500',
  },
  LIVE: {
    style: 'bg-emerald-50 text-emerald-800 border-emerald-200/80',
    dot: 'bg-emerald-500',
  },
  ON_DUTY: {
    style: 'bg-emerald-50 text-emerald-800 border-emerald-200/80',
    dot: 'bg-emerald-500',
  },
  OPEN: {
    style: 'bg-teal-50 text-teal-800 border-teal-200/80',
    dot: 'bg-teal-500',
  },

  // Pending / In Transit / Information
  PENDING: {
    style: 'bg-amber-50 text-amber-800 border-amber-200/80',
    dot: 'bg-amber-500',
  },
  IN_PROGRESS: {
    style: 'bg-sky-50 text-sky-800 border-sky-200/80',
    dot: 'bg-sky-500',
  },
  IN_TRANSIT: {
    style: 'bg-sky-50 text-sky-800 border-sky-200/80',
    dot: 'bg-sky-500',
  },
  DRIVER_ASSIGNED: {
    style: 'bg-indigo-50 text-indigo-800 border-indigo-200/80',
    dot: 'bg-indigo-500',
  },
  LOCKED: {
    style: 'bg-purple-50 text-purple-800 border-purple-200/80',
    dot: 'bg-purple-500',
  },
  OFF_DUTY: {
    style: 'bg-slate-100 text-slate-700 border-slate-200',
    dot: 'bg-slate-400',
  },
  MOCK: {
    style: 'bg-amber-50 text-amber-800 border-amber-200/80',
    dot: 'bg-amber-500',
  },

  // Negative / Cancelled / Suspended
  SUSPENDED: {
    style: 'bg-rose-50 text-rose-800 border-rose-200/80',
    dot: 'bg-rose-500',
  },
  CANCELLED: {
    style: 'bg-rose-50 text-rose-800 border-rose-200/80',
    dot: 'bg-rose-500',
  },
  REJECTED: {
    style: 'bg-rose-50 text-rose-800 border-rose-200/80',
    dot: 'bg-rose-500',
  },
};

const defaultStatus = {
  style: 'bg-slate-100 text-slate-700 border-slate-200',
  dot: 'bg-slate-400',
};

export default function Badge({ status, text, showDot = true }) {
  const normalized = (status || '').toUpperCase().replace(/\s+/g, '_');
  const config = statusConfig[normalized] || defaultStatus;

  return (
    <span
      className={`inline-flex items-center px-2.5 py-0.5 rounded-full text-[11px] font-semibold border tracking-wide shrink-0 ${config.style}`}
    >
      {showDot && (
        <span className={`w-1.5 h-1.5 rounded-full mr-1.5 shrink-0 ${config.dot}`} />
      )}
      <span>{text || status || '-'}</span>
    </span>
  );
}
