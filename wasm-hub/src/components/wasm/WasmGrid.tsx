import { WasmFile } from '../../services/firestore';
import { WasmCard } from './WasmCard';
import styles from './WasmGrid.module.css';

interface WasmGridProps {
  files: WasmFile[];
  loading?: boolean;
  emptyMessage?: string;
  showActions?: boolean;
  onToggleVisibility?: (file: WasmFile) => void;
  onDelete?: (file: WasmFile) => void;
}

export function WasmGrid({
  files,
  loading = false,
  emptyMessage = 'No WASM files found',
  showActions = false,
  onToggleVisibility,
  onDelete,
}: WasmGridProps) {
  if (loading) {
    return (
      <div className={styles.loading}>
        <div className={styles.spinner} />
        <p>Loading...</p>
      </div>
    );
  }

  if (files.length === 0) {
    return (
      <div className={styles.empty}>
        <p>{emptyMessage}</p>
      </div>
    );
  }

  return (
    <div className={styles.grid}>
      {files.map((file) => (
        <WasmCard
          key={file.id}
          file={file}
          showActions={showActions}
          onToggleVisibility={onToggleVisibility}
          onDelete={onDelete}
        />
      ))}
    </div>
  );
}
