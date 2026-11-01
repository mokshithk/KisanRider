import React from 'react';

export default function StatCard({ title, value, subtitle, icon: Icon, badge, color = 'forest' }) {
  return (
    <div className="bg-white rounded-lg border border-surface-border p-5 shadow-xs hover:border-gray-300 transition-colors">
      <div className="flex items-center justify-between">
        <span className="text-xs font-semibold uppercase tracking-wider text-text-secondary">
          {title}
        </span>
        {Icon && (
          <div className="p-2 rounded bg-surface-subtle text-forest">
            <Icon className="w-4 h-4" />
          </div>
        )}
      </div>
      <div className="mt-3 flex items-baseline justify-between">
        <span className="text-2xl font-bold tracking-tight text-text-primary">
          {value}
        </span>
        {badge && (
          <span className="text-xs font-medium px-2 py-0.5 rounded bg-lime-muted text-forest border border-lime-accent/30">
            {badge}
          </span>
        )}
      </div>
      {subtitle && (
        <p className="mt-1 text-xs text-text-secondary">
          {subtitle}
        </p>
      )}
    </div>
  );
}
