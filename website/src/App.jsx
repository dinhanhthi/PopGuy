import { useEffect } from "react";
import {
  BrowserRouter,
  Navigate,
  Route,
  Routes,
  useLocation
} from "react-router-dom";
import { Footer } from "./components/Footer";
import { Header } from "./components/Header";
import { ActionsPage } from "./pages/ActionsPage";
import { DocsPage } from "./pages/DocsPage";
import { HomePage } from "./pages/HomePage";
import { PrivacyPage } from "./pages/PrivacyPage";

const titles = {
  "/": "PopGuy — AI where you write",
  "/actions": "Actions — PopGuy",
  "/docs": "Docs — PopGuy",
  "/privacy": "Privacy — PopGuy"
};

export function AppRoutes() {
  const location = useLocation();

  useEffect(() => {
    document.title = titles[location.pathname] ?? titles["/"];
  }, [location.pathname]);

  return (
    <div className="page">
      <a className="skip-link" href="#main-content">Skip to content</a>
      <Header />
      <div id="main-content">
        <Routes>
          <Route path="/" element={<HomePage />} />
          <Route path="/actions" element={<ActionsPage />} />
          <Route path="/docs" element={<DocsPage />} />
          <Route path="/privacy" element={<PrivacyPage />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </div>
      <Footer />
    </div>
  );
}

export default function App() {
  return (
    <BrowserRouter>
      <AppRoutes />
    </BrowserRouter>
  );
}