import React from 'react';
import { ChevronLeft, ChevronRight, Inbox } from 'lucide-react';

export default function DataTable({
  columns,
  data = [],
  total = 0,
  page = 1,
  limit = 10,
  totalPages = 1,
  onPageChange,
  isLoading = false,
  emptyMessage = 'No records found matching your criteria.',
}) {
  return (
    <div className="bg-white rounded-xl border border-surface-border shadow-xs overflow-hidden">
      <div className="overflow-x-auto">
        <table className="w-full text-left border-collapse">
          <thead>
            <tr className="border-b border-surface-border bg-surface-subtle/60 text-text-secondary text-[11px] font-semibold uppercase tracking-wider">
              {columns.map((col, idx) => (
                <th
                  key={idx}
                  className={`px-5 py-3.5 whitespace-nowrap ${
                    col.align === 'right'
                      ? 'text-right'
                      : col.align === 'center'
                      ? 'text-center'
                      : 'text-left'
                  }`}
                  style={{ width: col.width }}
                >
                  {col.header}
                </th>
              ))}
            </tr>
          </thead>
          <tbody className="divide-y divide-surface-border text-xs">
            {isLoading ? (
              // Loading skeleton rows
              Array.from({ length: Math.min(limit || 5, 5) }).map((_, rIdx) => (
                <tr key={rIdx} className="animate-pulse">
                  {columns.map((col, cIdx) => (
                    <td key={cIdx} className="px-5 py-4">
                      <div className="h-4 bg-slate-200/70 rounded-md w-3/4"></div>
                    </td>
                  ))}
                </tr>
              ))
            ) : data.length === 0 ? (
              <tr>
                <td
                  colSpan={columns.length}
                  className="px-5 py-14 text-center text-text-secondary"
                >
                  <div className="flex flex-col items-center justify-center space-y-2.5 max-w-sm mx-auto">
                    <div className="w-10 h-10 rounded-full bg-surface-subtle flex items-center justify-center text-text-muted">
                      <Inbox className="w-5 h-5" />
                    </div>
                    <p className="text-xs font-medium text-text-primary">{emptyMessage}</p>
                    <p className="text-[11px] text-text-secondary">
                      Try adjusting filters or checking connection parameters.
                    </p>
                  </div>
                </td>
              </tr>
            ) : (
              data.map((row, rIdx) => (
                <tr
                  key={row.id || rIdx}
                  className="hover:bg-surface-subtle/50 transition-colors text-text-primary"
                >
                  {columns.map((col, cIdx) => (
                    <td
                      key={cIdx}
                      className={`px-5 py-3.5 ${
                        col.align === 'right'
                          ? 'text-right'
                          : col.align === 'center'
                          ? 'text-center'
                          : 'text-left'
                      }`}
                    >
                      {col.render ? col.render(row) : (row[col.accessor] ?? '-')}
                    </td>
                  ))}
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>

      {/* Pagination Bar */}
      {totalPages > 0 && onPageChange && (
        <div className="px-5 py-3 border-t border-surface-border flex flex-col sm:flex-row items-center justify-between gap-3 text-xs text-text-secondary bg-surface-subtle/30">
          <div>
            Showing{' '}
            <span className="font-semibold text-text-primary">
              {total === 0 ? 0 : (page - 1) * limit + 1}
            </span>{' '}
            to{' '}
            <span className="font-semibold text-text-primary">
              {Math.min(page * limit, total)}
            </span>{' '}
            of <span className="font-semibold text-text-primary">{total}</span> entries
          </div>

          <div className="flex items-center space-x-2">
            <button
              onClick={() => onPageChange(page - 1)}
              disabled={page <= 1 || isLoading}
              className="p-1.5 rounded-lg border border-surface-border bg-white text-text-primary hover:bg-surface-subtle disabled:opacity-40 disabled:cursor-not-allowed transition-colors shadow-xs"
              title="Previous page"
              aria-label="Previous page"
            >
              <ChevronLeft className="w-4 h-4" />
            </button>
            <span className="font-medium px-2.5 text-text-primary">
              Page {page} of {totalPages || 1}
            </span>
            <button
              onClick={() => onPageChange(page + 1)}
              disabled={page >= totalPages || isLoading}
              className="p-1.5 rounded-lg border border-surface-border bg-white text-text-primary hover:bg-surface-subtle disabled:opacity-40 disabled:cursor-not-allowed transition-colors shadow-xs"
              title="Next page"
              aria-label="Next page"
            >
              <ChevronRight className="w-4 h-4" />
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
