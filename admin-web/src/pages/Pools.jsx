import React, { useState, useEffect } from 'react';
import {
  Layers,
  Search,
  Eye,
  XCircle,
  RefreshCw,
  Users,
  MapPin,
  Calendar,
  AlertCircle,
  Clock,
} from 'lucide-react';
import { adminService } from '../services/adminService';
import DataTable from '../components/common/DataTable';
import Badge from '../components/common/Badge';
import ConfirmationModal from '../components/common/ConfirmationModal';
import DetailModal from '../components/common/DetailModal';

export default function Pools() {
  const [pools, setPools] = useState([]);
  const [total, setTotal] = useState(0);
  const [page, setPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [loading, setLoading] = useState(true);

  // Filters
  const [cropType, setCropType] = useState('ALL');
  const [statusFilter, setStatusFilter] = useState('ALL');

  // Detail Modal
  const [selectedPool, setSelectedPool] = useState(null);
  const [detailLoading, setDetailLoading] = useState(false);
  const [isDetailOpen, setIsDetailOpen] = useState(false);

  // Cancellation Modal
  const [cancelModal, setCancelModal] = useState({
    isOpen: false,
    pool: null,
  });
  const [cancelLoading, setCancelLoading] = useState(false);
  const [toastMessage, setToastMessage] = useState('');

  const fetchPools = async (currentPage = page) => {
    setLoading(true);
    try {
      const params = {
        page: currentPage,
        limit: 10,
        status_filter: statusFilter,
      };
      if (cropType !== 'ALL') params.crop_type = cropType;

      const res = await adminService.getPools(params);
      setPools(res.items || []);
      setTotal(res.total || 0);
      setPage(res.page || 1);
      setTotalPages(res.total_pages || 1);
    } catch (err) {
      console.error('Failed to fetch farmer pools:', err);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchPools(1);
  }, [cropType, statusFilter]);

  const openDetail = async (pool) => {
    setIsDetailOpen(true);
    setDetailLoading(true);
    try {
      const data = await adminService.getPoolDetail(pool.id);
      setSelectedPool(data);
    } catch (err) {
      console.error('Failed to load pool detail:', err);
    } finally {
      setDetailLoading(false);
    }
  };

  const handleCancelConfirm = async (reason) => {
    const { pool } = cancelModal;
    if (!pool) return;

    setCancelLoading(true);
    try {
      await adminService.cancelPool(pool.id, reason);
      setToastMessage(`Pool #${pool.id.slice(0, 8)} has been cancelled.`);
      setCancelModal({ isOpen: false, pool: null });
      fetchPools(page);
      setTimeout(() => setToastMessage(''), 4000);
    } catch (err) {
      console.error('Failed to cancel pool:', err);
      const detail = err.response?.data?.detail || 'Pool cancellation rejected by business rules.';
      alert(`Error: ${detail}`);
    } finally {
      setCancelLoading(false);
    }
  };

  const columns = [
    {
      header: 'Pool ID',
      accessor: 'id',
      render: (row) => (
        <span className="font-mono text-xs font-semibold text-text-primary">
          #{row.id.slice(0, 8)}
        </span>
      ),
    },
    {
      header: 'Creator Farmer',
      accessor: 'creator_name',
      render: (row) => (
        <div>
          <span className="font-semibold text-text-primary block">{row.creator_name}</span>
          <span className="text-[11px] text-text-secondary">{row.creator_phone || '-'}</span>
        </div>
      ),
    },
    {
      header: 'Crop Type',
      accessor: 'crop_type',
      render: (row) => <span className="font-semibold text-forest">{row.crop_type}</span>,
    },
    {
      header: 'Combined Qty',
      accessor: 'current_qty',
      render: (row) => (
        <div>
          <span className="font-bold text-text-primary block">{row.current_qty} kg</span>
          <span className="text-[10px] text-text-secondary">
            Min: {row.min_qty} • Max: {row.max_qty} kg
          </span>
        </div>
      ),
    },
    {
      header: 'Farmers',
      accessor: 'members_count',
      render: (row) => (
        <span className="inline-flex items-center space-x-1 px-2 py-0.5 rounded bg-surface-subtle text-text-primary font-medium text-xs">
          <Users className="w-3 h-3 text-text-secondary" />
          <span>{row.members_count || 1}</span>
        </span>
      ),
    },
    {
      header: 'Destination Mandi',
      accessor: 'dropoff_mandi_name',
      render: (row) => (
        <div>
          <span className="block font-medium text-text-primary truncate max-w-[150px]">
            {row.dropoff_mandi_name || 'APMC Yard'}
          </span>
          <span className="text-[11px] text-text-secondary">{row.dropoff_district || 'Karnataka'}</span>
        </div>
      ),
    },
    {
      header: 'Pool Status',
      accessor: 'status',
      render: (row) => <Badge status={row.status} />,
    },
    {
      header: 'Assigned Driver',
      accessor: 'assigned_rider',
      render: (row) => (
        <span className="text-xs text-text-secondary">
          {row.assigned_rider || <span className="text-text-muted italic">Unassigned</span>}
        </span>
      ),
    },
    {
      header: 'Actions',
      align: 'right',
      render: (row) => {
        const canCancel = !['COMPLETED', 'CANCELLED'].includes(row.status);
        return (
          <div className="flex items-center justify-end space-x-1.5">
            <button
              onClick={() => openDetail(row)}
              className="p-1.5 rounded text-text-secondary hover:text-forest hover:bg-surface-subtle transition-colors"
              title="Inspect Pool"
            >
              <Eye className="w-4 h-4" />
            </button>
            {canCancel && (
              <button
                onClick={() => setCancelModal({ isOpen: true, pool: row })}
                className="p-1.5 rounded text-rose-600 hover:bg-rose-50 transition-colors"
                title="Cancel Pool"
              >
                <XCircle className="w-4 h-4" />
              </button>
            )}
          </div>
        );
      },
    },
  ];

  return (
    <div className="space-y-5">
      {/* Information Header */}
      <div className="p-3.5 bg-white rounded-lg border border-surface-border text-xs text-text-secondary flex items-start space-x-2.5 shadow-xs">
        <AlertCircle className="w-4 h-4 text-forest shrink-0 mt-0.5" />
        <p className="leading-relaxed">
          <strong className="text-text-primary">Farmer Pooling Architecture:</strong> Neighboring
          farmers consolidate small yields into refrigerated shared transport. Admins supervise
          routing, review stop sequences, and intervene if scheduling or road delays occur.
        </p>
      </div>

      {toastMessage && (
        <div className="p-3 rounded-lg bg-emerald-50 border border-emerald-200 text-xs font-semibold text-emerald-900 animate-in fade-in">
          {toastMessage}
        </div>
      )}

      {/* Filter Bar */}
      <div className="bg-white p-4 rounded-lg border border-surface-border flex flex-col md:flex-row md:items-center justify-between gap-3 shadow-xs">
        <div className="flex items-center space-x-3">
          <select
            value={statusFilter}
            onChange={(e) => setStatusFilter(e.target.value)}
            className="text-xs rounded border border-surface-border px-3 py-2 bg-white text-text-primary focus:outline-none focus:ring-1 focus:ring-forest"
          >
            <option value="ALL">All Pool Statuses</option>
            <option value="OPEN">Open (Accepting Members)</option>
            <option value="DRIVER_ASSIGNED">Driver Assigned</option>
            <option value="LOCKED">Locked</option>
            <option value="IN_PROGRESS">In Progress</option>
            <option value="COMPLETED">Completed</option>
            <option value="CANCELLED">Cancelled</option>
          </select>
        </div>

        <button
          onClick={() => fetchPools(page)}
          className="p-2 rounded border border-surface-border text-text-secondary hover:text-text-primary hover:bg-surface-subtle transition-colors"
          title="Refresh list"
        >
          <RefreshCw className={`w-3.5 h-3.5 ${loading ? 'animate-spin' : ''}`} />
        </button>
      </div>

      {/* Pools Table */}
      <DataTable
        columns={columns}
        data={pools}
        total={total}
        page={page}
        limit={10}
        totalPages={totalPages}
        onPageChange={(p) => fetchPools(p)}
        isLoading={loading}
        emptyMessage="No farmer pools found matching criteria."
      />

      {/* Confirmation Modal */}
      <ConfirmationModal
        isOpen={cancelModal.isOpen}
        onClose={() => setCancelModal({ isOpen: false, pool: null })}
        onConfirm={handleCancelConfirm}
        title="Cancel Farmer Freight Pool"
        actionType="danger"
        affectedRecord={
          cancelModal.pool
            ? `Pool #${cancelModal.pool.id.slice(0, 8)} (${cancelModal.pool.crop_type} • ${cancelModal.pool.current_qty} kg)`
            : ''
        }
        consequences="Cancelling this pool notifies participating farmers and releases all attached produce batches from the collective manifest."
        requireReason={true}
        reasonPlaceholder="Specify administrative reason for cancelling this pool..."
        confirmText="Confirm Pool Cancellation"
        isLoading={cancelLoading}
      />

      {/* Detail Modal */}
      <DetailModal
        isOpen={isDetailOpen}
        onClose={() => setIsDetailOpen(false)}
        title={selectedPool ? `Freight Pool #${selectedPool.pool.id.slice(0, 8)}` : 'Pool Details'}
        subtitle={`Crop: ${selectedPool?.pool.crop_type || ''} • Total Manifest: ${selectedPool?.pool.current_qty || 0} kg`}
        maxWidth="max-w-3xl"
      >
        {detailLoading ? (
          <div className="py-12 text-center text-text-secondary text-xs">Loading pool data...</div>
        ) : selectedPool ? (
          <div className="space-y-6">
            {/* Highlights */}
            <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 bg-surface-subtle p-3.5 rounded-lg border border-surface-border text-xs">
              <div>
                <span className="text-text-secondary block">Pool Status</span>
                <Badge status={selectedPool.pool.status} />
              </div>
              <div>
                <span className="text-text-secondary block">Capacity Range</span>
                <span className="font-semibold text-text-primary block mt-0.5">
                  {selectedPool.pool.min_qty} - {selectedPool.pool.max_qty} kg
                </span>
              </div>
              <div>
                <span className="text-text-secondary block">Current Tonnage</span>
                <span className="font-semibold text-forest block mt-0.5">
                  {selectedPool.pool.current_qty} kg
                </span>
              </div>
              <div>
                <span className="text-text-secondary block">Mandi Destination</span>
                <span className="font-semibold text-text-primary block mt-0.5 truncate">
                  {selectedPool.pool.dropoff_mandi_name || 'APMC Yard'}
                </span>
              </div>
            </div>

            {/* Window and Notes */}
            <div className="bg-white p-3.5 rounded border border-surface-border text-xs space-y-1.5">
              <span className="font-bold uppercase tracking-wider text-text-secondary block">
                Pickup Window & Logistics Notes
              </span>
              <p>
                <strong className="text-text-primary">Window Start:</strong>{' '}
                {selectedPool.pool.pickup_window_start ? new Date(selectedPool.pool.pickup_window_start).toLocaleString() : '-'}
              </p>
              <p>
                <strong className="text-text-primary">Window End:</strong>{' '}
                {selectedPool.pool.pickup_window_end ? new Date(selectedPool.pool.pickup_window_end).toLocaleString() : '-'}
              </p>
              {selectedPool.pool.notes && (
                <p>
                  <strong className="text-text-primary">Notes:</strong> {selectedPool.pool.notes}
                </p>
              )}
            </div>

            {/* Participating Farmers */}
            <div>
              <h4 className="text-xs font-bold uppercase tracking-wider text-text-secondary mb-2">
                Participating Farmers ({selectedPool.members?.length || 0})
              </h4>
              <div className="space-y-2">
                {selectedPool.members?.length > 0 ? (
                  selectedPool.members.map((m) => (
                    <div key={m.id} className="p-2.5 rounded bg-surface-bg border border-surface-border text-xs flex justify-between items-center">
                      <div>
                        <span className="font-semibold text-text-primary block">{m.farmer_name}</span>
                        <span className="text-text-secondary text-[11px] block mt-0.5">
                          Phone: {m.farmer_phone || '-'} • Requested: {m.requested_at ? new Date(m.requested_at).toLocaleDateString() : '-'}
                        </span>
                      </div>
                      <div className="text-right">
                        <span className="font-bold text-forest block">{m.weight_kg} kg</span>
                        <Badge status={m.status} />
                      </div>
                    </div>
                  ))
                ) : (
                  <p className="text-xs text-text-muted">No member dispatches attached to this pool.</p>
                )}
              </div>
            </div>

            {/* Pickup Stops */}
            <div>
              <h4 className="text-xs font-bold uppercase tracking-wider text-text-secondary mb-2">
                Optimized Pickup Sequence ({selectedPool.stops?.length || 0} stops)
              </h4>
              <div className="space-y-2">
                {selectedPool.stops?.length > 0 ? (
                  selectedPool.stops.map((s) => (
                    <div key={s.id} className="p-2.5 rounded bg-surface-bg border border-surface-border text-xs flex justify-between items-center">
                      <div className="flex items-center space-x-2.5">
                        <span className="w-5 h-5 rounded-full bg-forest text-lime-accent flex items-center justify-center font-bold text-[10px]">
                          {s.sequence}
                        </span>
                        <div>
                          <span className="font-medium text-text-primary block">{s.pickup_address}</span>
                          <span className="text-text-secondary text-[11px]">Payload: {s.weight_kg} kg</span>
                        </div>
                      </div>
                      <Badge status={s.status} />
                    </div>
                  ))
                ) : (
                  <p className="text-xs text-text-muted">No sequential stops mapped yet.</p>
                )}
              </div>
            </div>
          </div>
        ) : null}
      </DetailModal>
    </div>
  );
}
