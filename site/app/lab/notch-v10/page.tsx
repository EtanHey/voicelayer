import { HybridNotchPrototype } from "../../../components/notch-lab/hybrid/HybridNotchPrototype";

import styles from "./notch-v10.module.css";

export default function NotchV10UnifiedPage() {
  return (
    <main
      aria-label="Unified liquid glass full-screen mock"
      className={`${styles.page} purple-audit`}
    >
      <HybridNotchPrototype />
    </main>
  );
}
