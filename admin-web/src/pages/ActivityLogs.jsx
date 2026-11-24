import React, { useState, useEffect } from 'react';
import {
  Search,
  Eye,
  RefreshCw,
  Shield,
} from 'lucide-react';
import { adminService } from '../services/adminService';
import DataTable from '../components/common/DataTable';
import DetailModal from '../components/common/DetailModal';

export default function ActivityLogs() {
  const [logs, setLogs] = useState([]);
  const [total, setTotal] = useState(0);
  const [page, setPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [loading, setLoading] = useState(true);

  // Filters
  const [moduleFilter, setModuleFilter] = useState('ALL');
  const [searchTerm, setSearchTerm] = useState('');

  // Detail Modal
  const [selectedLog, setSelectedLog] = useState(null);
  const [isDetailOpen, setIsDetailOpen] = useState(false);

  const fetchLogs = async (currentPage = page) => {
    setLoading(true);
    try {
      const params = {
        page: currentPage,
        limit: 15,
        module: moduleFilter,
      };
      if (searchTerm.trim()) params.search = searchTerm.trim();

      const res = await adminService.getActivityLogs(params);
      setLogs(res.items || []);
      setTotal(res.total || 0);
      setPage(res.page || 1);
      setTotalPages(res.total_pages || 1);
    } catch (err) {
      console.error('Failed to fetch activity logs:', err);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchLogs(1);
  }, [moduleFilter]);

  const handleSearchSubmit = (e) => {
    e.preventDefault();
    fetchLogs(1);
  };

  const columns = [
    {
      header: 'Log ID',
      accessor: 'id',
      render: (row) => (
        <span className="font-mono text-[11px] text-text-secondary">
          #{row.id.slice(0, 8)}
        </span>
      ),
    },
    {
      header: 'Administrator',
      accessor: 'admin_name',
      render: (row) => (
        <div>
          <span className="font-semibold text-text-primary block text-xs leading-tight">{row.admin_name}</span>
          <span className="text-[11px] text-text-secondary mt-0.5 block">{row.admin_email}</span>
        </div>
      ),
    },
    {
      header: 'Action',
      accessor: 'action',
      render: (row) => (
        <span className="font-mono font-bold text-xs text-forest">
          {row.action}
        </span>
      ),
    },
    {
      header: 'Module',
      accessor: 'module',
      render: (row) => (
        <span className="text-[11px] font-semibold px-2.5 py-0.5 rounded-full bg-surface-subtle border border-surface-border text-text-primary">
          {row.module}
        </span>
      ),
    },
    {
      header: 'Affected Record',
      accessor: 'record_id',
      render: (row) => (
        <span className="font-mono text-xs text-text-secondary">
          {row.record_id ? `#${row.record_id.slice(0, 8)}` : '-'}
        </span>
      ),
    },
    {
      header: 'Timestamp',
      accessor: 'created_at',
      render: (row) => (
        <span className="text-xs text-text-secondary whitespace-nowrap">
          {row.created_at ? new Date(row.created_at).toLocaleString() : '-'}
        </span>
      ),
    },
    {
      header: 'Summary',
      accessor: 'description',
      render: (row) => (
        <span className="text-xs text-text-primary truncate max-w-[200px] block" title={row.description}>
          {row.description}
        </span>
      ),
    },
    {
      header: 'Details',
      align: 'right',
      render: (row) => (
        <button
          onClick={() => {
            setSelectedLog(row);
            setIsDetailOpen(true);
          }}
          className="p-1.5 rounded-lg text-text-secondary hover:text-forest hover:bg-surface-subtle transition-colors"
          title="Inspect Audit Log"
          aria-label="Inspect Audit Log"
        >
          <Eye className="w-4 h-4" />
        </button>
      ),
    },
  ];

  return (
    <div className="space-y-5">
      {/* Immutability Banner */}
      <div className="p-4 bg-white rounded-xl border border-surface-border text-xs text-text-secondary flex items-start space-x-3 shadow-xs">
        <Shield className="w-4 h-4 text-forest shrink-0 mt-0.5" />
        <p className="leading-relaxed">
          <strong className="text-text-primary font-semibold">Append-Only Audit Security:</strong> Activity logs
          are immutable. Every consequential administrative decision—including status transitions,
          cancellations, invitations, and financial reconciliations—is permanently preserved. No
          delete or modification endpoints exist.
        </p>
      </div>

      {/* Filter and Search Bar */}
      <div className="bg-white p-4 rounded-xl border border-surface-border flex flex-col md:flex-row md:items-center justify-between gap-3 shadow-xs">
        <form onSubmit={handleSearchSubmit} className="flex-1 flex items-center space-x-2">
          <div className="relative flex-1 max-w-md">
            <Search className="w-4 h-4 absolute left-3 top-2.5 text-text-muted" />
            <input
              type="text"
              value={searchTerm}
              onChange={(e) => setSearchTerm(e.target.value)}
              placeholder="Search by description, admin email, record ID..."
              className="w-full text-xs rounded-lg border border-surface-border pl-9 pr-3 py-2 bg-white text-text-primary placeholder:text-text-muted focus:outline-none focus:ring-2 focus:ring-forest/20 focus:border-forest transition-all"
            />
          </div>
          <button
            type="submit"
            className="px-4 py-2 text-xs font-semibold rounded-lg bg-forest text-white hover:bg-forest-light transition-colors shadow-xs"
          >
            Search
          </button>
        </form>

        <div className="flex items-center space-x-3">
          <select
            value={moduleFilter}
            onChange={(e) => setModuleFilter(e.target.value)}
            className="text-xs rounded-lg border border-surface-border px-3 py-2 bg-white text-text-primary focus:outline-none focus:ring-2 focus:ring-forest/20 focus:border-forest transition-all"
          >
            <option value="ALL">All Modules</option>
            <option value="AUTH">Auth</option>
            <option value="FARMERS">Farmers</option>
            <option value="RIDERS">Riders</option>
            <option value="TRIPS">Trips</option>
            <option value="POOLS">Farmer Pools</option>
            <option value="SETTLEMENTS">Settlements</option>
            <option value="ADMIN_MANAGEMENT">Admin Management</option>
          </select>

          <button
            onClick={() => fetchLogs(page)}
            className="p-2 rounded-lg border border-surface-border text-text-secondary hover:text-text-primary hover:bg-surface-subtle transition-colors shadow-xs"
            title="Refresh logs"
            aria-label="Refresh logs"
          >
            <RefreshCw className={`w-3.5 h-3.5 ${loading ? 'animate-spin text-forest' : ''}`} />
          </button>
        </div>
      </div>

      {/* Activity Logs Table */}
      <DataTable
        columns={columns}
        data={logs}
        total={total}
        page={page}
        limit={15}
        totalPages={totalPages}
        onPageChange={(p) => fetchLogs(p)}
        isLoading={loading}
        emptyMessage="No audit logs recorded for query."
      />

      {/* Detail Modal */}
      <DetailModal
        isOpen={isDetailOpen}
        onClose={() => setIsDetailOpen(false)}
        title={selectedLog ? `Audit Record #${selectedLog.id.slice(0, 8)}` : 'Log Details'}
        subtitle={`Action: ${selectedLog?.action || ''} • Timestamp: ${
          selectedLog?.created_at ? new Date(selectedLog.created_at).toLocaleString() : ''
        }`}
        maxWidth="max-w-2xl"
      >
        {selectedLog && (
          <div className="space-y-4 text-xs">
            <div className="grid grid-cols-2 gap-3 bg-surface-subtle/70 p-4 rounded-xl border border-surface-border">
              <div>
                <span className="text-text-secondary block font-medium">Administrator</span>
                <span className="font-semibold text-text-primary block mt-1">
                  {selectedLog.admin_name} ({selectedLog.admin_email})
                </span>
              </div>
              <div>
                <span className="text-text-secondary block font-medium">IP Address</span>
                <span className="font-mono text-text-primary block mt-1">{selectedLog.ip_address || 'Internal/Localhost'}</span>
              </div>
              <div>
                <span className="text-text-secondary block font-medium">Module</span>
                <span className="font-semibold text-text-primary block mt-1">{selectedLog.module}</span>
              </div>
              <div>
                <span className="text-text-secondary block font-medium">Target Record</span>
                <span className="font-mono text-text-primary block mt-1">{selectedLog.record_id || 'Global / Batch'}</span>
              </div>
            </div>

            <div>
              <h4 className="font-bold uppercase tracking-wider text-text-secondary mb-1.5 text-[11px]">
                Operation Summary
              </h4>
              <p className="bg-white p-3.5 rounded-xl border border-surface-border text-text-primary leading-relaxed">
                {selectedLog.description}
              </p>
            </div>

            {selectedLog.changes && (
              <div>
                <h4 className="font-bold uppercase tracking-wider text-text-secondary mb-1.5 text-[11px]">
                  State Changes Payload (JSON)
                </h4>
                <pre className="bg-forest-dark text-emerald-300 p-3.5 rounded-xl text-[11px] font-mono overflow-x-auto">
                  {(() => {
                    try {
                      return JSON.stringify(JSON.parse(selectedLog.changes), null, 2);
                    } catch {
                      return selectedLog.changes;
                    }
                  })()}
                </pre>
              </div>
            )}
          </div>
        )}
      </DetailModal>
    </div>
  );
}
