import React from 'react';

export default function StatCard({ title, value, subtitle, icon: Icon, badge }) {
  return (
    <div className="bg-white rounded-xl border border-surface-border p-5 shadow-xs hover:shadow-card hover:border-emerald-300/60 transition-all flex flex-col justify-between">
      <div>
        <div className="flex items-center justify-between">
          <span className="text-[11px] font-semibold uppercase tracking-wider text-text-secondary">
            {title}
          </span>
          {Icon && (
            <div className="p-2 rounded-lg bg-surface-subtle text-forest">
              <Icon className="w-4 h-4" />
            </div>
          )}
        </div>
        <div className="mt-3 flex items-baseline justify-between gap-2">
          <span className="text-2xl font-bold tracking-tight text-text-primary">
            {value}
          </span>
          {badge && (
            <span className="inline-flex items-center text-[11px] font-medium px-2 py-0.5 rounded-full bg-lime-subtle text-forest border border-lime-200 shrink-0">
              {badge}
            </span>
          )}
        </div>
      </div>
      {subtitle && (
        <p className="mt-2 text-xs text-text-secondary leading-snug">
          {subtitle}
        </p>
      )}
    </div>
  );
}
