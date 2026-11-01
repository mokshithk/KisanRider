import React, { useState, useEffect } from 'react';
import {
  Search,
  Eye,
  XCircle,
  RefreshCw,
  Navigation,
  QrCode,
  AlertCircle,
  CheckCircle2,
  Calendar,
} from 'lucide-react';
import { adminService } from '../services/adminService';
import DataTable from '../components/common/DataTable';
import Badge from '../components/common/Badge';
import ConfirmationModal from '../components/common/ConfirmationModal';
import DetailModal from '../components/common/DetailModal';

export default function Trips() {
  const [trips, setTrips] = useState([]);
  const [total, setTotal] = useState(0);
  const [page, setPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [loading, setLoading] = useState(true);

  // Filters
  const [searchTerm, setSearchTerm] = useState('');
  const [statusFilter, setStatusFilter] = useState('ALL');

  // Detail Modal
  const [selectedTrip, setSelectedTrip] = useState(null);
  const [detailLoading, setDetailLoading] = useState(false);
  const [isDetailOpen, setIsDetailOpen] = useState(false);

  // Cancellation Modal
  const [cancelModal, setCancelModal] = useState({
    isOpen: false,
    trip: null,
  });
  const [cancelLoading, setCancelLoading] = useState(false);
  const [toastMessage, setToastMessage] = useState('');

  const fetchTrips = async (currentPage = page) => {
    setLoading(true);
    try {
      const params = {
        page: currentPage,
        limit: 10,
        status_filter: statusFilter,
      };
      if (searchTerm.trim()) params.search = searchTerm.trim();

      const res = await adminService.getTrips(params);
      setTrips(res.items || []);
      setTotal(res.total || 0);
      setPage(res.page || 1);
      setTotalPages(res.total_pages || 1);
    } catch (err) {
      console.error('Failed to fetch trips:', err);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchTrips(1);
  }, [statusFilter]);

  const handleSearchSubmit = (e) => {
    e.preventDefault();
    fetchTrips(1);
  };

  const openDetail = async (trip) => {
    setIsDetailOpen(true);
    setDetailLoading(true);
    try {
      const data = await adminService.getTripDetail(trip.id);
      setSelectedTrip(data);
    } catch (err) {
      console.error('Failed to load trip detail:', err);
    } finally {
      setDetailLoading(false);
    }
  };

  const handleCancelConfirm = async (reason) => {
    const { trip } = cancelModal;
    if (!trip) return;

    setCancelLoading(true);
    try {
      await adminService.cancelTrip(trip.id, reason);
      setToastMessage(`Trip #${trip.id.slice(0, 8)} has been cancelled.`);
      setCancelModal({ isOpen: false, trip: null });
      fetchTrips(page);
      setTimeout(() => setToastMessage(''), 4000);
    } catch (err) {
      console.error('Failed to cancel trip:', err);
      const detail = err.response?.data?.detail || 'Trip cancellation rejected by business rules.';
      alert(`Error: ${detail}`);
    } finally {
      setCancelLoading(false);
    }
  };

  const columns = [
    {
      header: 'Trip ID',
      accessor: 'id',
      render: (row) => (
        <span className="font-mono text-xs font-semibold text-text-primary">
          #{row.id.slice(0, 8)}
        </span>
      ),
    },
    {
      header: 'Rider / Vehicle',
      accessor: 'rider_name',
      render: (row) => (
        <div>
          <span className="font-semibold text-text-primary block">{row.rider_name}</span>
          <span className="text-[11px] text-text-secondary">{row.rider_phone || '-'}</span>
        </div>
      ),
    },
    {
      header: 'Farmer',
      accessor: 'farmer_name',
      render: (row) => (
        <div>
          <span className="font-medium text-text-primary block">{row.farmer_name}</span>
          <span className="text-[11px] text-text-secondary">
            {row.crop_type} ({row.weight_kg} kg)
          </span>
        </div>
      ),
    },
    {
      header: 'Freight Pool',
      accessor: 'pool_id',
      render: (row) =>
        row.pool_id ? (
          <span className="font-mono text-[11px] px-2 py-0.5 rounded bg-surface-subtle text-forest border border-surface-border">
            Pool #{row.pool_id.slice(0, 6)}
          </span>
        ) : (
          <span className="text-text-muted text-xs">Direct Haul</span>
        ),
    },
    {
      header: 'Pickup & Mandi',
      accessor: 'pickup_address',
      render: (row) => (
        <div className="max-w-[180px]">
          <span className="block truncate text-text-primary text-xs" title={row.pickup_address}>
            From: {row.pickup_address || 'Origin'}
          </span>
          <span className="block truncate text-text-secondary text-[11px]" title={row.destination}>
            To: {row.destination || 'Mandi'}
          </span>
        </div>
      ),
    },
    {
      header: 'Trip Status',
      accessor: 'status',
      render: (row) => <Badge status={row.status} />,
    },
    {
      header: 'Date Created',
      accessor: 'created_at',
      render: (row) =>
        row.created_at ? new Date(row.created_at).toLocaleDateString() : '-',
    },
    {
      header: 'Actions',
      align: 'right',
      render: (row) => {
        const isEligibleForCancel = !['DELIVERED', 'COMPLETED', 'CANCELLED'].includes(row.status);
        return (
          <div className="flex items-center justify-end space-x-1.5">
            <button
              onClick={() => openDetail(row)}
              className="p-1.5 rounded text-text-secondary hover:text-forest hover:bg-surface-subtle transition-colors"
              title="Inspect Trip"
            >
              <Eye className="w-4 h-4" />
            </button>
            {isEligibleForCancel && (
              <button
                onClick={() => setCancelModal({ isOpen: true, trip: row })}
                className="p-1.5 rounded text-rose-600 hover:bg-rose-50 transition-colors"
                title="Cancel Trip"
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
          <strong className="text-text-primary">Operational Rule:</strong> Completed or delivered
          trips cannot be cancelled. Administrative cancellation requires a mandatory audit reason
          and safely transitions active telemetry states.
        </p>
      </div>

      {toastMessage && (
        <div className="p-3 rounded-lg bg-emerald-50 border border-emerald-200 text-xs font-semibold text-emerald-900 animate-in fade-in">
          {toastMessage}
        </div>
      )}

      {/* Search and Filters */}
      <div className="bg-white p-4 rounded-lg border border-surface-border flex flex-col md:flex-row md:items-center justify-between gap-3 shadow-xs">
        <form onSubmit={handleSearchSubmit} className="flex-1 flex items-center space-x-2">
          <div className="relative flex-1 max-w-md">
            <Search className="w-4 h-4 absolute left-3 top-2.5 text-text-secondary" />
            <input
              type="text"
              value={searchTerm}
              onChange={(e) => setSearchTerm(e.target.value)}
              placeholder="Search by pickup address or trip ID..."
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
            value={statusFilter}
            onChange={(e) => setStatusFilter(e.target.value)}
            className="text-xs rounded border border-surface-border px-3 py-2 bg-white text-text-primary focus:outline-none focus:ring-1 focus:ring-forest"
          >
            <option value="ALL">All Trip Statuses</option>
            <option value="ACCEPTED">Accepted</option>
            <option value="IN_TRANSIT">In Transit</option>
            <option value="DELIVERED">Delivered</option>
            <option value="CANCELLED">Cancelled</option>
          </select>

          <button
            onClick={() => fetchTrips(page)}
            className="p-2 rounded border border-surface-border text-text-secondary hover:text-text-primary hover:bg-surface-subtle transition-colors"
            title="Refresh list"
          >
            <RefreshCw className={`w-3.5 h-3.5 ${loading ? 'animate-spin' : ''}`} />
          </button>
        </div>
      </div>

      {/* Trips Table */}
      <DataTable
        columns={columns}
        data={trips}
        total={total}
        page={page}
        limit={10}
        totalPages={totalPages}
        onPageChange={(p) => fetchTrips(p)}
        isLoading={loading}
        emptyMessage="No trips matching criteria."
      />

      {/* Cancellation Confirmation Modal */}
      <ConfirmationModal
        isOpen={cancelModal.isOpen}
        onClose={() => setCancelModal({ isOpen: false, trip: null })}
        onConfirm={handleCancelConfirm}
        title="Administrative Trip Cancellation"
        actionType="danger"
        affectedRecord={
          cancelModal.trip ? `Trip #${cancelModal.trip.id.slice(0, 8)} (${cancelModal.trip.rider_name})` : ''
        }
        consequences="Cancelling this trip immediately halts transit tracking and marks both the trip and the linked produce dispatch as CANCELLED."
        requireReason={true}
        reasonPlaceholder="Specify operational reason for cancelling this trip..."
        confirmText="Confirm Trip Cancellation"
        isLoading={cancelLoading}
      />

      {/* Detail Modal */}
      <DetailModal
        isOpen={isDetailOpen}
        onClose={() => setIsDetailOpen(false)}
        title={selectedTrip ? `Trip #${selectedTrip.trip.id.slice(0, 8)}` : 'Trip Detail'}
        subtitle={
          selectedTrip?.trip.created_at
            ? `Dispatched on ${new Date(selectedTrip.trip.created_at).toLocaleString()}`
            : ''
        }
        maxWidth="max-w-3xl"
      >
        {detailLoading ? (
          <div className="py-12 text-center text-text-secondary text-xs">Loading trip lifecycle...</div>
        ) : selectedTrip ? (
          <div className="space-y-5">
            {/* Highlights */}
            <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 bg-surface-subtle p-3.5 rounded-lg border border-surface-border text-xs">
              <div>
                <span className="text-text-secondary block">Trip Status</span>
                <Badge status={selectedTrip.trip.status} />
              </div>
              <div>
                <span className="text-text-secondary block">Driver Assigned</span>
                <span className="font-semibold text-text-primary block mt-0.5">
                  {selectedTrip.rider?.full_name || 'Unassigned'}
                </span>
              </div>
              <div>
                <span className="text-text-secondary block">Completed At</span>
                <span className="font-semibold text-text-primary block mt-0.5">
                  {selectedTrip.trip.completed_at
                    ? new Date(selectedTrip.trip.completed_at).toLocaleTimeString()
                    : 'In Progress'}
                </span>
              </div>
              <div>
                <span className="text-text-secondary block">Handoff OTP</span>
                <span className="font-mono font-bold text-forest block mt-0.5">
                  {selectedTrip.produce_request?.pickup_otp || 'N/A'}
                </span>
              </div>
            </div>

            {/* Produce & Route Info */}
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-4 text-xs bg-white p-4 rounded border border-surface-border">
              <div className="space-y-1.5">
                <span className="font-bold uppercase tracking-wider text-text-secondary block">
                  Producer / Farm Origin
                </span>
                <p>
                  <strong className="text-text-primary">Farmer:</strong> {selectedTrip.farmer?.full_name}
                </p>
                <p>
                  <strong className="text-text-primary">Pickup:</strong> {selectedTrip.trip.pickup_address || 'Farm Gate'}
                </p>
                <p>
                  <strong className="text-text-primary">Crop:</strong> {selectedTrip.produce_request?.crop_type} ({selectedTrip.produce_request?.weight_kg} kg)
                </p>
              </div>
              <div className="space-y-1.5">
                <span className="font-bold uppercase tracking-wider text-text-secondary block">
                  Destination Market & Transport
                </span>
                <p>
                  <strong className="text-text-primary">Destination:</strong> {selectedTrip.produce_request?.dropoff_mandi_name || 'APMC Yard'}
                </p>
                <p>
                  <strong className="text-text-primary">Driver Phone:</strong> {selectedTrip.rider?.phone || '-'}
                </p>
                <p>
                  <strong className="text-text-primary">Vehicle Plate:</strong> {selectedTrip.rider?.vehicle_number || '-'}
                </p>
              </div>
            </div>

            {/* Crate Scans */}
            <div>
              <h4 className="text-xs font-bold uppercase tracking-wider text-text-secondary mb-2 flex items-center space-x-1.5">
                <QrCode className="w-4 h-4 text-forest" />
                <span>Crate Telemetry Scans ({selectedTrip.crate_scans?.length || 0})</span>
              </h4>
              <div className="space-y-2">
                {selectedTrip.crate_scans?.length > 0 ? (
                  selectedTrip.crate_scans.map((cs) => (
                    <div key={cs.id} className="p-2.5 rounded bg-surface-bg border border-surface-border text-xs flex justify-between items-center">
                      <div>
                        <span className="font-mono font-semibold text-text-primary">{cs.qr_code}</span>
                        <span className="text-[11px] text-text-secondary block mt-0.5">
                          Type: {cs.scan_type} • {cs.scanned_at ? new Date(cs.scanned_at).toLocaleString() : ''}
                        </span>
                      </div>
                      <Badge status="COMPLETED" text="Verified" />
                    </div>
                  ))
                ) : (
                  <p className="text-xs text-text-muted">No QR crate scans logged for this trip.</p>
                )}
              </div>
            </div>

            {/* Linked Settlement */}
            {selectedTrip.settlement && (
              <div className="p-3.5 bg-surface-subtle rounded border border-surface-border text-xs flex justify-between items-center">
                <div>
                  <span className="font-bold text-text-primary block">Financial Settlement Attached</span>
                  <span className="text-text-secondary mt-0.5 block">
                    Gross: ₹{selectedTrip.settlement.gross_amount} • Net Payout: ₹{selectedTrip.settlement.net_payout}
                  </span>
                </div>
                <Badge status={selectedTrip.settlement.status} />
              </div>
            )}
          </div>
        ) : null}
      </DetailModal>
    </div>
  );
}
