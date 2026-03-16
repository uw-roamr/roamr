import { useState, useRef, DragEvent, ChangeEvent } from 'react';
import {
  validateWasmFile,
  validateWasmMagicNumber,
  UploadProgress,
} from '../../services/storage';
import { Button } from '../ui';
import styles from './WasmUploader.module.css';

interface WasmUploaderProps {
  onFileSelect: (file: File) => void;
  progress?: UploadProgress | null;
  uploading?: boolean;
}

export function WasmUploader({
  onFileSelect,
  progress,
  uploading = false,
}: WasmUploaderProps) {
  const [dragActive, setDragActive] = useState(false);
  const [error, setError] = useState('');
  const [selectedFile, setSelectedFile] = useState<File | null>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  const handleDrag = (e: DragEvent) => {
    e.preventDefault();
    e.stopPropagation();
    if (e.type === 'dragenter' || e.type === 'dragover') {
      setDragActive(true);
    } else if (e.type === 'dragleave') {
      setDragActive(false);
    }
  };

  const handleDrop = async (e: DragEvent) => {
    e.preventDefault();
    e.stopPropagation();
    setDragActive(false);
    setError('');

    const files = e.dataTransfer.files;
    if (files.length > 0) {
      await processFile(files[0]);
    }
  };

  const handleChange = async (e: ChangeEvent<HTMLInputElement>) => {
    setError('');
    if (e.target.files && e.target.files.length > 0) {
      await processFile(e.target.files[0]);
    }
  };

  const processFile = async (file: File) => {
    const basicValidation = validateWasmFile(file);
    if (!basicValidation.valid) {
      setError(basicValidation.error || 'Invalid file');
      return;
    }

    const magicValidation = await validateWasmMagicNumber(file);
    if (!magicValidation.valid) {
      setError(magicValidation.error || 'Invalid WASM file');
      return;
    }

    setSelectedFile(file);
    onFileSelect(file);
  };

  const handleClick = () => {
    inputRef.current?.click();
  };

  return (
    <div className={styles.wrapper}>
      <div
        className={`${styles.dropzone} ${dragActive ? styles.active : ''} ${uploading ? styles.uploading : ''}`}
        onDragEnter={handleDrag}
        onDragLeave={handleDrag}
        onDragOver={handleDrag}
        onDrop={handleDrop}
        onClick={!uploading ? handleClick : undefined}
      >
        <input
          ref={inputRef}
          type="file"
          accept=".wasm"
          onChange={handleChange}
          className={styles.input}
          disabled={uploading}
        />

        {uploading && progress ? (
          <div className={styles.progress}>
            <div className={styles.progressIcon}>📦</div>
            <p className={styles.progressText}>
              Uploading {selectedFile?.name}...
            </p>
            <div className={styles.progressBar}>
              <div
                className={styles.progressFill}
                style={{ width: `${progress.percentage}%` }}
              />
            </div>
            <p className={styles.progressPercent}>
              {Math.round(progress.percentage)}%
            </p>
          </div>
        ) : (
          <>
            <div className={styles.icon}>📦</div>
            <p className={styles.text}>
              {selectedFile
                ? selectedFile.name
                : 'Drag & drop your .wasm file here'}
            </p>
            <p className={styles.subtext}>
              or click to browse (max 50MB)
            </p>
            <Button variant="secondary" size="sm" type="button">
              Select File
            </Button>
          </>
        )}
      </div>

      {error && <p className={styles.error}>{error}</p>}
    </div>
  );
}
