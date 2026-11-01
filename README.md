# KisanRider

In India's agrarian economy, small and marginal farmers face significant post-harvest losses 
due to fragmented supply chain logistics, lack of accessible cold-storage transportation, and 
exploitation by local intermediaries. Perishable produce, such as tomatoes, greens, and fruits, 
loses 25% to 30% of its market value during transit due to delayed transportation and un-
refrigerated haulage. Individual transport of small yields (e.g., 10–20 crates) to distant urban 
wholesale markets (Mandis) is cost-prohibitive for individual farmers. 

KisanRider is an integrated spatial logistics and freight-pooling platform engineered to solve 
farm-gate transport inefficiency. By combining Geographic Information Systems (GIS), 
mathematical route optimization, real-time telemetry, and open government data feeds, 
KisanRider enables neighboring farmers to pool their harvests into temperature-controlled, 
shared transport vehicles. The system automatically routes dispatches to regional Agricultural 
Produce Market Committee (APMC) Mandis offering the highest prevailing wholesale 
prices, maximizing net profit margins for smallholder farmers. 

---

## System Components

1. **Flutter Mobile/Web Application (`frontend/`)**: Used by Farmers and Riders for booking produce transport, managing duty status, QR crate scanning, and tracking collective freight pools.
2. **FastAPI Backend Server (`backend/`)**: REST APIs, spatial calculations via PostGIS, pooling lifecycle management, APMC mandi rates, and settlement accounting.
3. **Admin Web Portal (`admin-web/`)**: React 19 administration portal for operations supervision, farmer/rider account controls, trip cancellations, financial settlement reconciliation, mandi monitoring, audit logs, and reports.

### Initial Administrator Provisioning:
```bash
cd backend
python bootstrap_admin.py
```

### Launch Admin Web:
```bash
cd admin-web
npm install --legacy-peer-deps
npm run dev
```
See [`admin-web/README.md`](admin-web/README.md) for complete administration documentation.
