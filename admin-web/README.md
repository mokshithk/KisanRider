# KisanRider Admin Web — Production Administration Portal

A secure, minimalist, production-grade Web Administration platform engineered for **KisanRider**, India's spatial logistics and freight-pooling ecosystem for smallholder farmers.

---

## 1. Project Architecture

The KisanRider platform operates as a unified multi-client system backed by a single FastAPI application and PostgreSQL / Supabase PostGIS database:

```
                      +-----------------------------------+
                      |         KisanRider Admin Web      |
                      |   (React 19 / Vite / Tailwind)    |
                      +-----------------+-----------------+
                                        | HTTPS / REST API / JWT
                                        v
+-----------------------+     +-------------------+
|  Flutter Mobile / Web | --> |  FastAPI Backend  |
|  (Farmers & Riders)   |     |    (Python 3.13)  |
+-----------------------+     +---------+---------+
                                        |
                                        v
                              +-------------------+
                              | PostgreSQL 17.6   |
                              | Supabase / PostGIS|
                              +-------------------+
```

- **Single Shared Identity**: Reuses the core `User` model. Admins share the same identity table with role `ADMIN`.
- **Zero Schema Duplication**: Reuses existing `ProduceRequest`, `Trip`, `Pool`, `PoolMember`, `PoolStop`, and `Settlement` tables.
- **Append-Only Audit Trail**: Every administrative action is logged to `admin_activity_logs`.
- **Security Boundaries**: Farmers and Riders cannot access Admin APIs. Public signup is strictly restricted to Farmers and Riders.

---

## 2. Technology Stack

### Frontend
- **Framework**: React 19 + Vite 8
- **Language**: JavaScript (ES2023)
- **Styling**: Tailwind CSS (Hybrid Professional Palette: Forest Green `#173D2C`, Lime `#C8F53E`, Surface `#F4F7F3`, Card `#FFFFFF`)
- **Navigation**: React Router DOM 7
- **Icons**: Lucide React
- **Data Visualization**: Recharts
- **HTTP Client**: Axios with JWT interceptors
- **Testing**: Playwright (Headless Chromium)

### Backend Integration
- **Server**: FastAPI + Uvicorn
- **ORM**: SQLAlchemy + GeoAlchemy2
- **Validation**: Pydantic V2
- **Authentication**: JWT (HS256) + bcrypt password hashing (`passlib`)
- **Email Service**: Python `smtplib` (SMTP over SSL port 465)

---

## 3. Directory Structure

```
KisanRider/
├── backend/
│   ├── admin_router.py            # Admin API endpoints, business logic & audit helper
│   ├── auth.py                    # JWT & role authorization (require_role("ADMIN"), is_active)
│   ├── bootstrap_admin.py         # Secure interactive CLI for first admin creation
│   ├── crud.py                    # Database operations
│   ├── database.py                # Supabase PostgreSQL session factory
│   ├── main.py                    # FastAPI entrypoint
│   ├── models.py                  # User, AdminInvitation, AdminActivityLog models
│   ├── test_admin_api.py          # 15 automated backend test suites
│   └── migrations/
│       └── 001_admin_tables.py    # Safe additive SQL migration
├── admin-web/
│   ├── e2e/
│   │   └── admin.spec.js          # Playwright end-to-end browser tests
│   ├── src/
│   │   ├── components/
│   │   │   ├── common/            # Badge, StatCard, DataTable, ConfirmationModal, DetailModal
│   │   │   └── layout/            # Layout, Navbar, Sidebar
│   │   ├── context/
│   │   │   └── AuthContext.jsx    # Session management & JWT lifecycle
│   │   ├── pages/
│   │   │   ├── Login.jsx          # Secure admin login
│   │   │   ├── Dashboard.jsx      # 8 KPI cards, 4 charts, recent activity
│   │   │   ├── Farmers.jsx        # Farmer oversight, suspension/reactivation
│   │   │   ├── Riders.jsx         # Driver oversight, duty/suspension controls
│   │   │   ├── TransportRequests.jsx # Produce request monitoring
│   │   │   ├── Trips.jsx          # Trip lifecycle and safe cancellation
│   │   │   ├── Pools.jsx          # Collective freight pool oversight
│   │   │   ├── Settlements.jsx    # Financial payout verification & reconciliation
│   │   │   ├── MandiPrices.jsx    # APMC wholesale price monitoring
│   │   │   ├── Reports.jsx        # Aggregated analytics & CSV file streaming
│   │   │   ├── AdminManagement.jsx# Administrator invitations & listing
│   │   │   ├── ActivityLogs.jsx   # Immutable append-only audit trail
│   │   │   ├── Profile.jsx        # Password management & session termination
│   │   │   └── AcceptInvitation.jsx # Single-use token onboarding
│   │   ├── services/
│   │   │   ├── api.js             # Axios client with bearer token injection
│   │   │   └── adminService.js    # Typed backend service calls
│   │   ├── App.jsx                # Router & protected route guards
│   │   └── main.jsx               # Entrypoint
│   ├── .env.example
│   ├── package.json
│   ├── playwright.config.js
│   └── tailwind.config.js
└── README.md
```

---

## 4. Setup and Installation

### Prerequisites
- Node.js `v24.x` and npm `11.x`
- Python `3.13.x` with backend virtual environment

### 1. Database Migrations
Run the safe, non-destructive migration script to add `is_active` to `users`, and create `admin_invitations` and `admin_activity_logs`:

```bash
cd D:\kisanRider-project\KisanRider\backend
.\venv\Scripts\python.exe migrations\001_admin_tables.py
```

### 2. Initial Admin Account Provisioning
Because no admin accounts exist initially, provision the first administrator using the interactive bootstrap CLI:

```bash
cd D:\kisanRider-project\KisanRider\backend
.\venv\Scripts\python.exe bootstrap_admin.py
```
- Prompts interactively for **Admin Full Name**, **Email Address**, and **Password** (hidden input via `getpass`).
- Securely hashes the password with bcrypt.
- Sets role to `ADMIN` and status to active.
- Logs the bootstrap event in `admin_activity_logs`.
- **Duplicate Protection**: Refuses to run if any `ADMIN` already exists in the database.

### 3. Frontend Installation
```bash
cd D:\kisanRider-project\KisanRider\admin-web
npm install --legacy-peer-deps
```

### 4. Environment Configuration
Copy `.env.example` to `.env`:

```env
VITE_API_BASE_URL=http://localhost:8000
```

---

## 5. Running the Application

### Start the FastAPI Backend:
```bash
cd D:\kisanRider-project\KisanRider\backend
.\venv\Scripts\python.exe -m uvicorn main:app --host 127.0.0.1 --port 8000 --reload
```

### Start the Admin Web Development Server:
```bash
cd D:\kisanRider-project\KisanRider\admin-web
npm run dev
```
Open your browser at `http://localhost:5173`.

---

## 6. Administrative Operations & Features

### 1. Admin Management & Multi-Admin Onboarding
- Existing administrators can invite additional staff from **Admin Management** (`/admin-management`).
- Enter the candidate's full name and email.
- The system generates a cryptographically secure random token (`secrets.token_urlsafe(32)`).
- Only a SHA-256 hash of the token is stored in `admin_invitations` with a 24-hour expiry.
- An email is dispatched via SMTP (or provided as a direct single-use link).
- The candidate visits `/accept-invitation?token=...`, sets their password, and activates their account.
- Invitation tokens are single-use and cannot be replayed.

### 2. Consequential Actions & Audit Logging
The following administrative actions trigger mandatory confirmation and append an immutable record to `admin_activity_logs`:
- Suspend / Reactivate Farmer account
- Suspend / Reactivate Rider account
- Cancel Trip (delivering / delivered trips cannot be cancelled)
- Cancel Farmer Freight Pool
- Reconcile Financial Settlement (requires external payment reference / UTR number)

### 3. Reports & CSV Export
- Under **Reports & Analytics** (`/reports`), select category:
  - Farmers
  - Riders
  - Transport Requests
  - Trips
  - Farmer Pools
  - Settlements
- Filter by date range.
- Click **Download Official CSV** to stream an actual comma-separated file generated from live database queries.

---

## 7. Testing

### Run Backend Tests (15 Automated Tests):
```bash
cd D:\kisanRider-project\KisanRider\backend
.\venv\Scripts\python.exe -m pytest test_admin_api.py -v
```

### Run Playwright Browser E2E Tests:
```bash
cd D:\kisanRider-project\KisanRider\admin-web
node run-e2e.cjs
```

---

## 8. Production Build

To compile an optimized production distribution:
```bash
cd D:\kisanRider-project\KisanRider\admin-web
npm run build
```
Build outputs are located in `dist/`.
