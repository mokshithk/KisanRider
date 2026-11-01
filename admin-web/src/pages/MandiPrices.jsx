import React, { useState, useEffect } from 'react';
import {
  TrendingUp,
  Search,
  Filter,
  RefreshCw,
  Database,
  Globe,
  AlertCircle,
} from 'lucide-react';
import { adminService } from '../services/adminService';
import DataTable from '../components/common/DataTable';
import Badge from '../components/common/Badge';

export default function MandiPrices() {
  const [prices, setPrices] = useState([]);
  const [source, setSource] = useState('mock');
  const [isLive, setIsLive] = useState(false);
  const [districts, setDistricts] = useState([]);
  const [loading, setLoading] = useState(true);

  // Filters
  const [district, setDistrict] = useState('ALL');
  const [cropSearch, setCropSearch] = useState('');

  const fetchPrices = async () => {
    setLoading(true);
    try {
      const params = {};
      if (district !== 'ALL') params.district = district;
      if (cropSearch.trim()) params.crop = cropSearch.trim();

      const res = await adminService.getMandiPrices(params);
      setPrices(res.prices || []);
      setSource(res.source || 'mock');
      setIsLive(res.is_live_data || false);
      if (res.available_districts) setDistricts(res.available_districts);
    } catch (err) {
      console.error('Failed to load mandi prices:', err);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchPrices();
  }, [district]);

  const handleSearch = (e) => {
    e.preventDefault();
    fetchPrices();
  };

  const columns = [
    {
      header: 'Crop Commodity',
      accessor: 'crop',
      render: (row) => <span className="font-semibold text-forest text-xs">{row.crop}</span>,
    },
    {
      header: 'APMC Market Yard',
      accessor: 'mandi',
      render: (row) => <span className="font-medium text-text-primary text-xs">{row.mandi}</span>,
    },
    {
      header: 'District',
      accessor: 'district',
      render: (row) => <span className="text-text-secondary text-xs">{row.district}</span>,
    },
    {
      header: 'Modal Price',
      accessor: 'modal_price',
      render: (row) => (
        <span className="font-bold text-text-primary text-xs bg-surface-subtle px-2 py-0.5 rounded border border-surface-border">
          {row.modal_price}
        </span>
      ),
    },
    {
      header: 'Data Source',
      align: 'right',
      render: () => (
        <Badge
          status={isLive ? 'LIVE' : 'MOCK'}
          text={isLive ? 'Live Data.gov.in' : 'Mock Fallback Feed'}
        />
      ),
    },
  ];

  return (
    <div className="space-y-5">
      {/* Transparency Banner */}
      <div
        className={`p-4 rounded-lg border text-xs flex items-start space-x-3 shadow-xs ${
          isLive
            ? 'bg-emerald-50 border-emerald-200 text-emerald-900'
            : 'bg-amber-50 border-amber-200 text-amber-900'
        }`}
      >
        {isLive ? (
          <Globe className="w-5 h-5 text-emerald-700 shrink-0 mt-0.5" />
        ) : (
          <Database className="w-5 h-5 text-amber-700 shrink-0 mt-0.5" />
        )}
        <div>
          <span className="font-bold block">
            {isLive
              ? 'Connected to Live Agmarknet Data Feed'
              : 'Operating on Local Fallback Dataset (Mock)'}
          </span>
          <p className="mt-0.5 leading-relaxed">
            {isLive
              ? 'Market rates are streamed live via the Open Government Data Platform (data.gov.in). APMC mandi wholesale rates are monitored in real time.'
              : 'DATA_GOV_API_KEY is not configured or remote upstream is uncontactable. Displaying accurate historical baseline rates for all 31 Karnataka APMCs.'}
          </p>
        </div>
      </div>

      {/* Filter and Search Bar */}
      <div className="bg-white p-4 rounded-lg border border-surface-border flex flex-col md:flex-row md:items-center justify-between gap-3 shadow-xs">
        <form onSubmit={handleSearch} className="flex-1 flex items-center space-x-2">
          <div className="relative flex-1 max-w-md">
            <Search className="w-4 h-4 absolute left-3 top-2.5 text-text-secondary" />
            <input
              type="text"
              value={cropSearch}
              onChange={(e) => setCropSearch(e.target.value)}
              placeholder="Search crop commodity (Tomato, Onion, Coffee...)"
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
            value={district}
            onChange={(e) => setDistrict(e.target.value)}
            className="text-xs rounded border border-surface-border px-3 py-2 bg-white text-text-primary focus:outline-none focus:ring-1 focus:ring-forest"
          >
            <option value="ALL">All Karnataka Districts</option>
            {districts.map((d) => (
              <option key={d} value={d}>
                {d}
              </option>
            ))}
          </select>

          <button
            onClick={fetchPrices}
            className="p-2 rounded border border-surface-border text-text-secondary hover:text-text-primary hover:bg-surface-subtle transition-colors"
            title="Refresh prices"
          >
            <RefreshCw className={`w-3.5 h-3.5 ${loading ? 'animate-spin' : ''}`} />
          </button>
        </div>
      </div>

      {/* Mandi Table */}
      <DataTable
        columns={columns}
        data={prices}
        total={prices.length}
        page={1}
        limit={prices.length}
        totalPages={1}
        isLoading={loading}
        emptyMessage="No mandi price records found for specified commodity and district."
      />
    </div>
  );
}
