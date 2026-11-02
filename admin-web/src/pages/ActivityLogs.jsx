import React, { useState, useEffect } from 'react';
import {
  History,
  Search,
  Filter,
  Eye,
  RefreshCw,
  Shield,
  Clock,
  Terminal,
} from 'lucide-react';
import { adminService } from '../services/adminService';
import DataTable from '../components/common/DataTable';
import Badge from '../components/common/Badge';
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
          <span className="font-semibold text-text-primary block text-xs">{row.admin_name}</span>
          <span className="text-[11px] text-text-secondary">{row.admin_email}</span>
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
        <span className="text-xs font-semibold px-2 py-0.5 rounded bg-surface-subtle border border-surface-border text-text-primary">
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
          className="p-1 rounded text-text-secondary hover:text-forest hover:bg-surface-subtle transition-colors"
          title="Inspect Audit Log"
        >
          <Eye className="w-4 h-4" />
        </button>
      ),
    },
  ];

  return (
    <div className="space-y-5">
      {/* Immutability Banner */}
      <div className="p-3.5 bg-white rounded-lg border border-surface-border text-xs text-text-secondary flex items-start space-x-2.5 shadow-xs">
        <Shield className="w-4 h-4 text-forest shrink-0 mt-0.5" />
        <p className="leading-relaxed">
          <strong className="text-text-primary">Append-Only Audit Security:</strong> Activity logs
          are immutable. Every consequential administrative decision—including status transitions,
          cancellations, invitations, and financial reconciliations—is permanently preserved. No
          delete or modification endpoints exist.
        </p>
      </div>

      {/* Filter and Search Bar */}
      <div className="bg-white p-4 rounded-lg border border-surface-border flex flex-col md:flex-row md:items-center justify-between gap-3 shadow-xs">
        <form onSubmit={handleSearchSubmit} className="flex-1 flex items-center space-x-2">
          <div className="relative flex-1 max-w-md">
            <Search className="w-4 h-4 absolute left-3 top-2.5 text-text-secondary" />
            <input
              type="text"
              value={searchTerm}
              onChange={(e) => setSearchTerm(e.target.value)}
              placeholder="Search by description, admin email, record ID..."
              className="w-full text-xs rounded border border-surface-border pl-9 pr-3 py-2 focus:outline-none focus:ring-1 focus:ring-forest text-text-primary"
            />
          </div>
          <button
            type="submit"
            className="px-3.5 py-2 text-xs font-medium rounded bg-forest text-white hover:bg-forest-light transition-colors"
          >
            Search
          </button>
        </form>

        <div className="flex items-center space-x-3">
          <select
            value={moduleFilter}
            onChange={(e) => setModuleFilter(e.target.value)}
            className="text-xs rounded border border-surface-border px-3 py-2 bg-white text-text-primary focus:outline-none focus:ring-1 focus:ring-forest"
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
            className="p-2 rounded border border-surface-border text-text-secondary hover:text-text-primary hover:bg-surface-subtle transition-colors"
            title="Refresh logs"
          >
            <RefreshCw className={`w-3.5 h-3.5 ${loading ? 'animate-spin' : ''}`} />
          </button>
        </div>
      </div>

      {/* Logs Table */}
      <DataTable
        columns={columns}
        data={logs}
        total={total}
        page={page}
        limit={15}
        totalPages={totalPages}
        onPageChange={(p) => fetchLogs(p)}
        isLoading={loading}
        emptyMessage="No activity logs found."
      />

      {/* Detail Modal */}
      <DetailModal
        isOpen={isDetailOpen}
        onClose={() => setIsDetailOpen(false)}
        title={selectedLog ? `Audit Record #${selectedLog.id.slice(0, 8)}` : 'Audit Record'}
        subtitle={`Recorded on ${selectedLog?.created_at ? new Date(selectedLog.created_at).toLocaleString() : ''}`}
        maxWidth="max-w-2xl"
      >
        {selectedLog && (
          <div className="space-y-4">
            <div className="grid grid-cols-2 gap-3 text-xs bg-surface-subtle p-3.5 rounded border border-surface-border">
              <div>
                <span className="text-text-secondary block">Admin Performing Action:</span>
                <span className="font-semibold text-text-primary block mt-0.5">
                  {selectedLog.admin_name} ({selectedLog.admin_email})
                </span>
              </div>
              <div>
                <span className="text-text-secondary block">Module / Domain:</span>
                <span className="font-semibold text-text-primary block mt-0.5">
                  {selectedLog.module}
                </span>
              </div>
              <div>
                <span className="text-text-secondary block">Action Signature:</span>
                <span className="font-mono font-bold text-forest block mt-0.5">
                  {selectedLog.action}
                </span>
              </div>
              <div>
                <span className="text-text-secondary block">Client IP Address:</span>
                <span className="font-mono text-text-primary block mt-0.5">
                  {selectedLog.ip_address || 'Internal / Local'}
                </span>
              </div>
            </div>

            <div>
              <span className="text-xs font-bold uppercase tracking-wider text-text-secondary block mb-1">
                Full Description
              </span>
              <p className="text-xs text-text-primary p-3 bg-white rounded border border-surface-border leading-relaxed">
                {selectedLog.description}
              </p>
            </div>

            {selectedLog.changes && (
              <div>
                <span className="text-xs font-bold uppercase tracking-wider text-text-secondary block mb-1">
                  Delta State & Captured Context
                </span>
                <pre className="bg-forest-dark text-lime-accent p-3.5 rounded font-mono text-xs overflow-x-auto">
                  {JSON.stringify(selectedLog.changes, null, 2)}
                </pre>
              </div>
            )}
          </div>
        )}
      </DetailModal>
    </div>
  );
}
