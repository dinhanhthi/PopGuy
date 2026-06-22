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

const titles = {
  "/": "PopGuy — AI where you write",
  "/actions": "Actions — PopGuy",
  "/docs": "Docs — PopGuy"
};

export function AppRoutes() {
  const location = useLocation();

  useEffect(() => {
    document.title = titles[location.pathname] ?? titles["/"];
  }, [location.pathname]);

  return (
    <>
      <a className="skip-link" href="#main-content">Skip to content</a>
      <Header />
      <div id="main-content">
        <Routes>
          <Route path="/" element={<HomePage />} />
          <Route path="/actions" element={<ActionsPage />} />
          <Route path="/docs" element={<DocsPage />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </div>
      <Footer />
    </>
  );
}

export default function App() {
  return (
    <BrowserRouter>
      <AppRoutes />
    </BrowserRouter>
  );
}