import React, { useState, useEffect } from 'react';
import {
  Search,
  Eye,
  XCircle,
  RefreshCw,
  AlertCircle,
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
          <span className="font-semibold text-text-primary block leading-tight">{row.rider_name}</span>
          <span className="text-[11px] text-text-secondary mt-0.5 block">{row.rider_phone || '-'}</span>
        </div>
      ),
    },
    {
      header: 'Farmer',
      accessor: 'farmer_name',
      render: (row) => (
        <div>
          <span className="font-medium text-text-primary block leading-tight">{row.farmer_name}</span>
          <span className="text-[11px] text-text-secondary mt-0.5 block">
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
          <span className="font-mono text-[11px] px-2.5 py-0.5 rounded-full bg-surface-subtle text-forest border border-surface-border inline-block">
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
          <span className="block truncate text-text-secondary text-[11px] mt-0.5" title={row.destination}>
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
              className="p-1.5 rounded-lg text-text-secondary hover:text-forest hover:bg-surface-subtle transition-colors"
              title="Inspect Trip"
              aria-label="Inspect Trip"
            >
              <Eye className="w-4 h-4" />
            </button>
            {isEligibleForCancel && (
              <button
                onClick={() => setCancelModal({ isOpen: true, trip: row })}
                className="p-1.5 rounded-lg text-rose-600 hover:bg-rose-50 transition-colors"
                title="Cancel Trip"
                aria-label="Cancel Trip"
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
      <div className="p-4 bg-white rounded-xl border border-surface-border text-xs text-text-secondary flex items-start space-x-3 shadow-xs">
        <AlertCircle className="w-4 h-4 text-forest shrink-0 mt-0.5" />
        <p className="leading-relaxed">
          <strong className="text-text-primary font-semibold">Operational Rule:</strong> Completed or delivered
          trips cannot be cancelled. Administrative cancellation requires a mandatory audit reason
          and safely transitions active telemetry states.
        </p>
      </div>

      {toastMessage && (
        <div className="p-3.5 rounded-xl bg-emerald-50 border border-emerald-200/80 text-xs font-semibold text-emerald-900 animate-in fade-in">
          {toastMessage}
        </div>
      )}

      {/* Search and Filters */}
      <div className="bg-white p-4 rounded-xl border border-surface-border flex flex-col md:flex-row md:items-center justify-between gap-3 shadow-xs">
        <form onSubmit={handleSearchSubmit} className="flex-1 flex items-center space-x-2">
          <div className="relative flex-1 max-w-md">
            <Search className="w-4 h-4 absolute left-3 top-2.5 text-text-muted" />
            <input
              type="text"
              value={searchTerm}
              onChange={(e) => setSearchTerm(e.target.value)}
              placeholder="Search by pickup address or trip ID..."
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
            value={statusFilter}
            onChange={(e) => setStatusFilter(e.target.value)}
            className="text-xs rounded-lg border border-surface-border px-3 py-2 bg-white text-text-primary focus:outline-none focus:ring-2 focus:ring-forest/20 focus:border-forest transition-all"
          >
            <option value="ALL">All Trip Statuses</option>
            <option value="DRIVER_ASSIGNED">Driver Assigned</option>
            <option value="ACCEPTED">Accepted</option>
            <option value="IN_TRANSIT">In Transit</option>
            <option value="DELIVERED">Delivered</option>
            <option value="CANCELLED">Cancelled</option>
          </select>

          <button
            onClick={() => fetchTrips(page)}
            className="p-2 rounded-lg border border-surface-border text-text-secondary hover:text-text-primary hover:bg-surface-subtle transition-colors shadow-xs"
            title="Refresh list"
            aria-label="Refresh list"
          >
            <RefreshCw className={`w-3.5 h-3.5 ${loading ? 'animate-spin text-forest' : ''}`} />
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
        emptyMessage="No trips matching criteria found."
      />

      {/* Cancellation Modal */}
      <ConfirmationModal
        isOpen={cancelModal.isOpen}
        onClose={() => setCancelModal({ isOpen: false, trip: null })}
        onConfirm={handleCancelConfirm}
        title="Cancel Trip Dispatch"
        actionType="danger"
        affectedRecord={
          cancelModal.trip
            ? `Trip #${cancelModal.trip.id.slice(0, 8)} (${cancelModal.trip.crop_type} - ${cancelModal.trip.farmer_name})`
            : ''
        }
        consequences="Cancelling this trip immediately revokes driver assignment, returns produce to pending queue, and logs this action in the activity audit trail."
        requireReason={true}
        reasonPlaceholder="Specify administrative reason for trip cancellation..."
        confirmText="Confirm Trip Cancellation"
        isLoading={cancelLoading}
      />

      {/* Detail Modal */}
      <DetailModal
        isOpen={isDetailOpen}
        onClose={() => setIsDetailOpen(false)}
        title={selectedTrip ? `Trip #${selectedTrip.trip.id.slice(0, 8)} Details` : 'Trip Overview'}
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
          <div className="space-y-6">
            {/* Top Stat Overview */}
            <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 bg-surface-subtle/70 p-4 rounded-xl border border-surface-border text-xs">
              <div>
                <span className="text-text-secondary block font-medium">Trip Status</span>
                <div className="mt-1">
                  <Badge status={selectedTrip.trip.status} />
                </div>
              </div>
              <div>
                <span className="text-text-secondary block font-medium">Driver</span>
                <span className="font-semibold text-text-primary block mt-1">
                  {selectedTrip.rider?.full_name || 'Unassigned'}
                </span>
              </div>
              <div>
                <span className="text-text-secondary block font-medium">Crop & Weight</span>
                <span className="font-semibold text-text-primary block mt-1">
                  {selectedTrip.produce_request?.crop_type || '-'} ({selectedTrip.produce_request?.weight_kg || 0} kg)
                </span>
              </div>
              <div>
                <span className="text-text-secondary block font-medium">Delivery Mandi</span>
                <span className="font-semibold text-text-primary block mt-1 truncate">
                  {selectedTrip.produce_request?.dropoff_mandi_name || 'APMC Yard'}
                </span>
              </div>
            </div>

            {/* Origin & Destination Locations */}
            <div className="p-4 bg-white rounded-xl border border-surface-border space-y-3 text-xs">
              <h4 className="font-bold uppercase tracking-wider text-text-secondary text-[11px]">Route & Waypoints</h4>
              <div>
                <span className="text-text-secondary">Pickup Address (Farm Gate):</span>
                <p className="font-medium text-text-primary mt-0.5">{selectedTrip.produce_request?.pickup_address || '-'}</p>
              </div>
              <div>
                <span className="text-text-secondary">Dropoff Market:</span>
                <p className="font-medium text-text-primary mt-0.5">
                  {selectedTrip.produce_request?.dropoff_mandi_name} ({selectedTrip.produce_request?.dropoff_district || 'Karnataka'})
                </p>
              </div>
            </div>

            {/* Crate Scans */}
            <div>
              <h4 className="font-bold uppercase tracking-wider text-text-secondary mb-2.5 text-[11px]">
                Telemetry Crate Scans ({selectedTrip.crate_scans?.length || 0})
              </h4>
              <div className="space-y-2">
                {selectedTrip.crate_scans && selectedTrip.crate_scans.length > 0 ? (
                  selectedTrip.crate_scans.map((scan) => (
                    <div
                      key={scan.id}
                      className="p-3 rounded-lg bg-surface-subtle/50 border border-surface-border text-xs flex justify-between items-center"
                    >
                      <div>
                        <span className="font-mono font-semibold text-text-primary block">
                          Crate #{scan.crate_code || scan.id.slice(0, 8)}
                        </span>
                        <span className="text-text-secondary text-[11px] block mt-0.5">
                          {scan.scanned_at ? new Date(scan.scanned_at).toLocaleString() : 'Timestamp unavailable'}
                        </span>
                      </div>
                      <Badge status={scan.scan_type || 'COMPLETED'} />
                    </div>
                  ))
                ) : (
                  <p className="text-xs text-text-muted">No QR crate scans logged for this trip.</p>
                )}
              </div>
            </div>
          </div>
        ) : null}
      </DetailModal>
    </div>
  );
}
